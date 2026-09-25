import Foundation

/// Scores one lowercased text against a fuzzy query. Pure functions: no index, no database.
///
/// Score model: a match earns 10 per matched character minus the span between the first and
/// last match minus the gap penalty (characters skipped before each match), so contiguous and
/// early matches rank higher. Queries of one or two characters, and fuzzy+ ASCII words of three
/// or more characters, match as substrings; everything else matches as a subsequence.
enum FuzzyMatcher {
    struct PreparedQuery {
        let lower: String
        let isASCII: Bool
        let characterCount: Int
        let utf16Count: Int
        let safeFastUTF16: Bool
        let utf16Units: [UInt16]?
    }

    /// One compiled query for either fuzzy mode; `score(textLower:)` is the single scoring rule
    /// shared by the full index and the recent cache.
    struct Scorer {
        private enum PlusTerm {
            /// ASCII word of three or more characters: substring-only semantics.
            case substring(word: String, utf16Count: Int)
            case fuzzy(PreparedQuery)
        }

        private let mode: SearchMode
        private let query: PreparedQuery
        private let plusTerms: [PlusTerm]

        init(queryLower: String, mode: SearchMode) {
            self.mode = mode
            self.query = FuzzyMatcher.prepare(queryLower: queryLower)
            if mode == .fuzzyPlus {
                plusTerms = SearchQueryNormalization.fuzzyPlusTokens(queryLower).map { word in
                    if word.canBeConverted(to: .ascii), word.count >= 3 {
                        return .substring(word: word, utf16Count: word.utf16.count)
                    }
                    return .fuzzy(FuzzyMatcher.prepare(queryLower: word))
                }
            } else {
                plusTerms = []
            }
        }

        func score(textLower: String) -> Int? {
            switch mode {
            case .fuzzy:
                return FuzzyMatcher.score(textLower: textLower, query: query)
            case .fuzzyPlus:
                var totalScore = 0
                for term in plusTerms {
                    switch term {
                    case .substring(let word, let utf16Count):
                        guard let range = textLower.range(of: word) else { return nil }
                        let pos = range.lowerBound.utf16Offset(in: textLower)
                        totalScore += utf16Count * 10 - (utf16Count - 1) - pos
                    case .fuzzy(let prepared):
                        guard let termScore = FuzzyMatcher.score(textLower: textLower, query: prepared) else {
                            return nil
                        }
                        totalScore += termScore
                    }
                }
                return totalScore
            case .exact, .regex:
                return nil
            }
        }
    }

    static func prepare(queryLower: String) -> PreparedQuery {
        let isASCII = queryLower.canBeConverted(to: .ascii)
        let characterCount = queryLower.count
        if characterCount <= 2 {
            let safeFastUTF16 = isASCII || isSafeForFastUTF16Search(queryLower)
            if safeFastUTF16 {
                let units = Array(queryLower.utf16)
                return PreparedQuery(
                    lower: queryLower,
                    isASCII: isASCII,
                    characterCount: characterCount,
                    utf16Count: units.count,
                    safeFastUTF16: true,
                    utf16Units: units
                )
            }

            return PreparedQuery(
                lower: queryLower,
                isASCII: isASCII,
                characterCount: characterCount,
                utf16Count: queryLower.utf16.count,
                safeFastUTF16: false,
                utf16Units: nil
            )
        }

        if isASCII {
            let units = Array(queryLower.utf16)
            return PreparedQuery(
                lower: queryLower,
                isASCII: true,
                characterCount: characterCount,
                utf16Count: units.count,
                safeFastUTF16: true,
                utf16Units: units
            )
        }

        return PreparedQuery(
            lower: queryLower,
            isASCII: false,
            characterCount: characterCount,
            utf16Count: queryLower.utf16.count,
            safeFastUTF16: false,
            utf16Units: nil
        )
    }

    static func score(textLower: String, query: PreparedQuery) -> Int? {
        guard !query.lower.isEmpty else { return 0 }

        if query.characterCount <= 2 {
            guard let pos = findNeedleUTF16Offset(haystack: textLower, needle: query) else { return nil }
            let m = query.utf16Count
            return m * 10 - (m - 1) - pos
        }

        if query.isASCII, let queryUnits = query.utf16Units {
            return scoreASCIIUTF16(textLower: textLower, queryUnits: queryUnits)
        }

        // Fuzzy subsequence matching (non-contiguous). Implemented as a single pass to avoid
        // repeated `String.Index` distance computations on large/unicode-heavy texts.
        var queryIterator = query.lower.makeIterator()
        guard var queryChar = queryIterator.next() else { return 0 }

        var firstPos: Int?
        var lastPos = 0
        var gapPenalty = 0
        var matchedCount = 0
        var searchStartPos = 0

        var pos = 0
        for ch in textLower {
            if ch == queryChar {
                if firstPos == nil { firstPos = pos }
                gapPenalty += pos - searchStartPos
                matchedCount += 1
                lastPos = pos
                if let next = queryIterator.next() {
                    queryChar = next
                    searchStartPos = pos + 1
                } else {
                    break
                }
            }
            pos += 1
        }

        guard matchedCount == query.characterCount else { return nil }
        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
    }

    /// ASCII-only query: a single-pass subsequence match over UTF-16 code units avoids
    /// `Character` iteration on very large texts while keeping the same gap/span model.
    private static func scoreASCIIUTF16(textLower: String, queryUnits: [UInt16]) -> Int? {
        guard !queryUnits.isEmpty else { return 0 }

        var queryIndex = 0
        let queryCount = queryUnits.count
        var firstPos: Int?
        var lastPos = 0
        var gapPenalty = 0
        var matchedCount = 0
        var searchStartPos = 0

        var pos = 0
        for cu in textLower.utf16 {
            if cu == queryUnits[queryIndex] {
                if firstPos == nil { firstPos = pos }
                gapPenalty += pos - searchStartPos
                matchedCount += 1
                lastPos = pos
                queryIndex += 1
                if queryIndex >= queryCount { break }
                searchStartPos = pos + 1
            }
            pos += 1
        }

        guard matchedCount == queryCount else { return nil }
        let span = firstPos.map { lastPos - $0 } ?? 0
        return matchedCount * 10 - span - gapPenalty
    }

    private static func findNeedleUTF16Offset(haystack: String, needle: PreparedQuery) -> Int? {
        guard !needle.lower.isEmpty else { return 0 }

        if needle.safeFastUTF16, let needleUnits = needle.utf16Units {
            if needleUnits.count <= 4 {
                return findNeedleUTF16OffsetFast(haystack: haystack, needleUnits: needleUnits)
            }
        }

        guard let range = haystack.range(of: needle.lower) else { return nil }
        return range.lowerBound.utf16Offset(in: haystack)
    }

    /// Hot path: short needles (at most 4 UTF-16 units).
    private static func findNeedleUTF16OffsetFast(haystack: String, needleUnits: [UInt16]) -> Int? {
        guard let first = needleUnits.first else { return 0 }

        switch needleUnits.count {
        case 1:
            var pos = 0
            for cu in haystack.utf16 {
                if cu == first { return pos }
                pos += 1
            }
            return nil
        case 2:
            let second = needleUnits[1]
            var pos = 0
            var prev: UInt16? = nil
            for cu in haystack.utf16 {
                if prev == first, cu == second {
                    return pos - 1
                }
                prev = cu
                pos += 1
            }
            return nil
        case 3:
            let second = needleUnits[1]
            let third = needleUnits[2]
            var pos = 0
            var prev1: UInt16? = nil
            var prev2: UInt16? = nil
            for cu in haystack.utf16 {
                if prev2 == first, prev1 == second, cu == third {
                    return pos - 2
                }
                prev2 = prev1
                prev1 = cu
                pos += 1
            }
            return nil
        case 4:
            let second = needleUnits[1]
            let third = needleUnits[2]
            let fourth = needleUnits[3]
            var pos = 0
            var prev1: UInt16? = nil
            var prev2: UInt16? = nil
            var prev3: UInt16? = nil
            for cu in haystack.utf16 {
                if prev3 == first, prev2 == second, prev1 == third, cu == fourth {
                    return pos - 3
                }
                prev3 = prev2
                prev2 = prev1
                prev1 = cu
                pos += 1
            }
            return nil
        default:
            return nil
        }
    }

    /// Swift `String` search matches canonically equivalent sequences; the UTF-16 fast scan is
    /// only used for needles that are stable under canonical compose/decompose.
    private static func isSafeForFastUTF16Search(_ needle: String) -> Bool {
        let ns = needle as NSString
        if ns.precomposedStringWithCanonicalMapping != needle { return false }
        if ns.decomposedStringWithCanonicalMapping != needle { return false }
        return true
    }
}
