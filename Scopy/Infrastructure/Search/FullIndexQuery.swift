import Foundation

/// The complete index query: candidates, ranking and hydration all use one read snapshot.
/// Cold queries whose commit history has expired build and query that snapshot directly.
enum FullIndexQuery {
    static func execute(
        index: FullFuzzyIndex,
        shortIndex: ShortQueryIndex?,
        readStore: SearchReadStore,
        request: SearchRequest,
        mode: SearchMode,
        contentGeneration: UInt64,
        cache: inout FullIndexRanker.SortedMatchesCache?,
        perf: SearchPerfContext?
    ) throws -> SearchEngineImpl.QueryPage {
        let queryLower = request.query.lowercased()

        var candidateSlots: [Int]
        if let perf {
            candidateSlots = perf.measure("full_index_candidate_intersection") {
                FullIndexRanker.candidateSlots(index: index, queryLower: queryLower)
            }
        } else {
            candidateSlots = FullIndexRanker.candidateSlots(index: index, queryLower: queryLower)
        }

        // The character postings barely narrow ASCII words; the short index's bigram postings do.
        let bigrams = FullIndexRanker.requiredASCIIBigrams(queryLower: queryLower, mode: mode)
        if !bigrams.isEmpty, !candidateSlots.isEmpty, let shortIndex {
            let filterStart = perf == nil ? 0 : CFAbsoluteTimeGetCurrent()
            let matches = shortIndex.items(containingASCIIBigrams: bigrams)
            candidateSlots.removeAll { slot in
                index.items[slot].map { !matches.mayContain($0.id) } ?? false
            }
            perf?.addPhase("full_index_bigram_filter", ms: (CFAbsoluteTimeGetCurrent() - filterStart) * 1000)
            perf?.addCounter("full_index_bigram_candidate_slots", value: candidateSlots.count)
        }

        if candidateSlots.isEmpty {
            return SearchEngineImpl.QueryPage(items: [], total: 0, hasMore: false, coverage: .complete)
        }
        perf?.addCounter("full_index_candidate_slots", value: candidateSlots.count)

        let scorer = FuzzyMatcher.Scorer(queryLower: queryLower, mode: mode)

        // A large ASCII candidate set on the first interactive page is narrowed by FTS before
        // scoring; the page is then staged (total unknown) and the UI refines it later.
        var staged = false
        if let prefilterLimit = FullIndexRanker.adaptivePrefilterLimit(
            request: request,
            mode: mode,
            queryLower: queryLower,
            candidateCount: candidateSlots.count
        ) {
            perf?.addCounter("adaptive_prefilter_limit", value: prefilterLimit)
            if let ftsQuery = FTSQueryBuilder.build(userQuery: queryLower) {
                let ftsSlots: [Int]?
                if let perf {
                    ftsSlots = try? perf.measure("full_index_fts_prefilter_slots") {
                        try readStore.ftsPrefilterIDs(ftsQuery: ftsQuery, limit: prefilterLimit).compactMap { index.idToSlot[$0] }
                    }
                } else {
                    ftsSlots = try? readStore.ftsPrefilterIDs(ftsQuery: ftsQuery, limit: prefilterLimit).compactMap { index.idToSlot[$0] }
                }

                if let ftsSlots, !ftsSlots.isEmpty {
                    candidateSlots = FullIndexRanker.mergePrefilter(
                        candidateSlots: candidateSlots,
                        ftsSlots: ftsSlots,
                        index: index
                    )
                    perf?.addCounter("full_index_fts_prefilter_candidate_slots", value: candidateSlots.count)
                    staged = true
                }
            }
        }

        let page: FullIndexRanker.Page
        if staged {
            page = try FullIndexRanker.rankStaged(
                index: index,
                request: request,
                scorer: scorer,
                candidateSlots: candidateSlots,
                perf: perf
            )
        } else {
            page = try FullIndexRanker.rankComplete(
                index: index,
                request: request,
                mode: mode,
                queryLower: queryLower,
                scorer: scorer,
                candidateSlots: candidateSlots,
                indexContentVersion: contentGeneration,
                cache: &cache,
                perf: perf
            )
        }

        let pageIDs = page.slots.compactMap { index.items[$0]?.id }
        let resultItems: [ClipboardStoredItem]
        if staged, let perf {
            resultItems = try perf.measure("full_index_prefilter_fetch_items") {
                try readStore.fetchItemsByIDs(pageIDs)
            }
        } else {
            resultItems = try readStore.fetchItemsByIDs(pageIDs)
        }
        return SearchEngineImpl.QueryPage(items: resultItems, total: page.total, hasMore: page.hasMore, coverage: page.coverage)
    }

    static func readSnapshot(
        dbPath: String,
        request: SearchRequest,
        perf: SearchPerfContext?
    ) async throws -> SearchEngineImpl.SearchResult {
        let task = Task.detached(priority: .userInitiated) {
            let store = SearchReadStore(dbPath: dbPath)
            try store.open()
            defer { store.close() }
            return try store.withReadSnapshot { mutationSeq in
                try Task.checkCancellation()
                let index = try store.buildFullIndex()
                var cache: FullIndexRanker.SortedMatchesCache?
                let normalized = SearchRequest(
                    query: request.query.trimmingCharacters(in: .whitespacesAndNewlines),
                    mode: request.mode,
                    sortMode: request.sortMode,
                    appFilter: request.appFilter,
                    typeFilter: request.typeFilter,
                    typeFilters: request.typeFilters,
                    forceFullFuzzy: request.forceFullFuzzy,
                    limit: request.limit,
                    offset: request.offset
                )
                let page = try execute(index: index, shortIndex: nil, readStore: store,
                                       request: normalized, mode: request.mode, contentGeneration: 0,
                                       cache: &cache, perf: perf)
                return SearchEngineImpl.SearchResult(
                    items: page.items, total: page.total, hasMore: page.hasMore,
                    coverage: page.coverage, searchTimeMs: 0, mutationSeq: mutationSeq
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
