import Foundation

/// How a search query matches.
public enum SearchMode: String, Sendable, CaseIterable, Equatable, Hashable {
    case exact
    case fuzzy
    case fuzzyPlus  // Whitespace-separated words, each matched fuzzily.
    case regex
}
