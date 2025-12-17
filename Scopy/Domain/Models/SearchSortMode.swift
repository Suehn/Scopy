import Foundation

/// Search result sort mode.
///
/// Notes:
/// - Only affects the `.exact` mode when it uses FTS (typically query length >= 3).
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

