import Foundation

/// Search result sort mode.
///
/// Notes:
/// - Affects `.exact` when it uses FTS (typically query length >= 3).
/// - Also controls fuzzy/fuzzyPlus ordering when a query is present.
public enum SearchSortMode: String, Sendable, CaseIterable {
    case relevance
    case recent

    public var toggled: SearchSortMode {
        switch self {
        case .relevance: return .recent
        case .recent: return .relevance
        }
    }
}
