import Foundation

/// Query normalization shared by search execution and match-context building.
enum SearchQueryNormalization {
    static func fuzzyPlusTokens(_ queryLower: String) -> [String] {
        let trimmed = queryLower.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func normalizedExactQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldUseSubstringOnlyFallbackForFuzzyPlus(tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            token.count >= 3 && token.canBeConverted(to: .ascii)
        }
    }
}
