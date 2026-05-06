import Foundation

struct SearchPlan: Sendable, Equatable {
    let path: SearchPlanPath
    let coverage: SearchCoverage
    let reason: SearchPlanReason
    let requiredCapabilities: [SearchPlanCapability]
    let diagnostics: [SearchPlanDiagnostic]
}

enum SearchPlanPath: String, Sendable, Equatable {
    case allWithFilters = "all_with_filters"
    case exactRecentCache = "exact_recent_cache"
    case exactFTS = "exact_fts"
    case regexRecentCache = "regex_recent_cache"
    case interactiveFuzzyPrefilter = "interactive_fuzzy_prefilter"
    case fullIndexFuzzy = "full_index_fuzzy"
    case fuzzyPlusSubstringOnlyFallback = "fuzzy_plus_substring_only_fallback"
    case shortQueryFullIndex = "short_query_full_index"
    case shortQueryIndex = "short_query_index"
    case shortQueryIndexOrSQLFallback = "short_query_index_or_sql_fallback"
}

enum SearchPlanReason: String, Sendable, Equatable {
    case emptyQuery = "empty_query"
    case exactShortQueryRecentOnly = "exact_short_query_recent_only"
    case exactLongQueryFTS = "exact_long_query_fts"
    case exactFTSQueryUnavailable = "exact_fts_query_unavailable"
    case regexModeRecentOnly = "regex_mode_recent_only"
    case fuzzyInteractivePrefilter = "fuzzy_interactive_prefilter"
    case fuzzyLongQueryFullIndex = "fuzzy_long_query_full_index"
    case fuzzyPlusForcedSubstringOnly = "fuzzy_plus_forced_substring_only"
    case fuzzyShortQueryFullIndexReady = "fuzzy_short_query_full_index_ready"
    case fuzzyShortQueryShortIndexReady = "fuzzy_short_query_short_index_ready"
    case fuzzyShortQueryIndexFallback = "fuzzy_short_query_index_fallback"
}

enum SearchPlanCapability: String, Sendable, Equatable {
    case allItemsSQL = "all_items_sql"
    case recentCache = "recent_cache"
    case fts = "fts"
    case fullFuzzyIndex = "full_fuzzy_index"
    case shortQueryIndex = "short_query_index"
    case sqlSubstring = "sql_substring"
    case regexEngine = "regex_engine"
    case fuzzyScoring = "fuzzy_scoring"
    case interactiveRefine = "interactive_refine"
}

struct SearchPlanDiagnostic: Sendable, Equatable {
    let key: String
    let value: String
}

enum SearchPlanner {
    enum Constants {
        static let shortQueryCacheLimit = 2_000
    }

    struct State: Sendable, Equatable {
        let fullIndexReady: Bool
        let shortQueryIndexReady: Bool
        let prefersFTSForFuzzy: Bool
        let shortQueryCacheLimit: Int

        init(
            fullIndexReady: Bool = false,
            shortQueryIndexReady: Bool = false,
            prefersFTSForFuzzy: Bool = false,
            shortQueryCacheLimit: Int = Constants.shortQueryCacheLimit
        ) {
            self.fullIndexReady = fullIndexReady
            self.shortQueryIndexReady = shortQueryIndexReady
            self.prefersFTSForFuzzy = prefersFTSForFuzzy
            self.shortQueryCacheLimit = shortQueryCacheLimit
        }
    }

    static func plan(request: SearchRequest, state: State = State()) -> SearchPlan {
        switch request.mode {
        case .exact:
            return planExact(request: request, state: state)
        case .fuzzy, .fuzzyPlus:
            return planFuzzy(request: request, state: state)
        case .regex:
            return makePlan(
                path: .regexRecentCache,
                coverage: .recentOnly(limit: state.shortQueryCacheLimit),
                reason: .regexModeRecentOnly,
                requiredCapabilities: [.regexEngine, .recentCache],
                request: request,
                state: state
            )
        }
    }

    private static func planExact(request: SearchRequest, state: State) -> SearchPlan {
        if request.query.isEmpty {
            return allWithFilters(request: request, state: state, reason: .emptyQuery)
        }

        if request.query.count <= 2 {
            return makePlan(
                path: .exactRecentCache,
                coverage: .recentOnly(limit: state.shortQueryCacheLimit),
                reason: .exactShortQueryRecentOnly,
                requiredCapabilities: [.recentCache],
                request: request,
                state: state
            )
        }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FTSQueryBuilder.build(userQuery: trimmedQuery) != nil else {
            return allWithFilters(request: request, state: state, reason: .exactFTSQueryUnavailable)
        }

        return makePlan(
            path: .exactFTS,
            coverage: .complete,
            reason: .exactLongQueryFTS,
            requiredCapabilities: [.fts],
            request: request,
            state: state
        )
    }

    private static func planFuzzy(request: SearchRequest, state: State) -> SearchPlan {
        if request.query.isEmpty {
            return allWithFilters(request: request, state: state, reason: .emptyQuery)
        }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return allWithFilters(request: request, state: state, reason: .emptyQuery)
        }

        if request.forceFullFuzzy,
           request.mode == .fuzzyPlus,
           shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: fuzzyPlusTokens(trimmedQuery.lowercased())) {
            return makePlan(
                path: .fuzzyPlusSubstringOnlyFallback,
                coverage: .complete,
                reason: .fuzzyPlusForcedSubstringOnly,
                requiredCapabilities: [.sqlSubstring],
                request: request,
                state: state
            )
        }

        if !request.forceFullFuzzy,
           trimmedQuery.count >= 3,
           state.prefersFTSForFuzzy,
           FTSQueryBuilder.build(userQuery: trimmedQuery) != nil {
            return makePlan(
                path: .interactiveFuzzyPrefilter,
                coverage: .stagedRefine,
                reason: .fuzzyInteractivePrefilter,
                requiredCapabilities: [.fts, .interactiveRefine],
                request: request,
                state: state
            )
        }

        if trimmedQuery.count <= 2 {
            return planShortFuzzyQuery(request: request, state: state)
        }

        return makePlan(
            path: .fullIndexFuzzy,
            coverage: .complete,
            reason: .fuzzyLongQueryFullIndex,
            requiredCapabilities: [.fullFuzzyIndex, .fuzzyScoring],
            request: request,
            state: state
        )
    }

    private static func planShortFuzzyQuery(request: SearchRequest, state: State) -> SearchPlan {
        if state.fullIndexReady {
            return makePlan(
                path: .shortQueryFullIndex,
                coverage: .complete,
                reason: .fuzzyShortQueryFullIndexReady,
                requiredCapabilities: [.fullFuzzyIndex, .fuzzyScoring],
                request: request,
                state: state
            )
        }

        if state.shortQueryIndexReady {
            return makePlan(
                path: .shortQueryIndex,
                coverage: .complete,
                reason: .fuzzyShortQueryShortIndexReady,
                requiredCapabilities: [.shortQueryIndex, .sqlSubstring],
                request: request,
                state: state
            )
        }

        return makePlan(
            path: .shortQueryIndexOrSQLFallback,
            coverage: .complete,
            reason: .fuzzyShortQueryIndexFallback,
            requiredCapabilities: [.shortQueryIndex, .sqlSubstring],
            request: request,
            state: state
        )
    }

    private static func allWithFilters(
        request: SearchRequest,
        state: State,
        reason: SearchPlanReason
    ) -> SearchPlan {
        makePlan(
            path: .allWithFilters,
            coverage: .complete,
            reason: reason,
            requiredCapabilities: [.allItemsSQL],
            request: request,
            state: state
        )
    }

    private static func makePlan(
        path: SearchPlanPath,
        coverage: SearchCoverage,
        reason: SearchPlanReason,
        requiredCapabilities: [SearchPlanCapability],
        request: SearchRequest,
        state: State
    ) -> SearchPlan {
        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchPlan(
            path: path,
            coverage: coverage,
            reason: reason,
            requiredCapabilities: requiredCapabilities,
            diagnostics: [
                SearchPlanDiagnostic(key: "query_length", value: String(request.query.count)),
                SearchPlanDiagnostic(key: "trimmed_query_length", value: String(trimmedQuery.count)),
                SearchPlanDiagnostic(key: "full_index_ready", value: String(state.fullIndexReady)),
                SearchPlanDiagnostic(key: "short_query_index_ready", value: String(state.shortQueryIndexReady)),
                SearchPlanDiagnostic(key: "prefers_fts_for_fuzzy", value: String(state.prefersFTSForFuzzy))
            ]
        )
    }

    static func fuzzyPlusTokens(_ queryLower: String) -> [String] {
        let trimmed = queryLower.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            token.count >= 3 && token.canBeConverted(to: .ascii)
        }
    }
}
