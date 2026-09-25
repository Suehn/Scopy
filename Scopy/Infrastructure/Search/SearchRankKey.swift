import Foundation

/// The one ordering rule for ranked search hits: pinned items first, then the sort mode's
/// primary key (recency or score), then the other key, then the UUID string as a stable
/// tie-break. SQL paths express the same rule as `ORDER BY is_pinned DESC, ... , id ASC`.
///
/// Hits without a score (recency pre-sorts) use a constant score; position-based hits use the
/// negated match position so that an earlier match is a higher score.
struct SearchRankKey {
    let isPinned: Bool
    let lastUsedAt: Date
    let score: Int
    let id: UUID

    init(isPinned: Bool, lastUsedAt: Date, score: Int, id: UUID) {
        self.isPinned = isPinned
        self.lastUsedAt = lastUsedAt
        self.score = score
        self.id = id
    }

    init(item: IndexedItem, score: Int) {
        self.init(isPinned: item.isPinned, lastUsedAt: item.lastUsedAt, score: score, id: item.id)
    }

    init(item: ClipboardStoredItem, score: Int) {
        self.init(isPinned: item.isPinned, lastUsedAt: item.lastUsedAt, score: score, id: item.id)
    }

    static func isBetter(_ lhs: SearchRankKey, than rhs: SearchRankKey, sortMode: SearchSortMode) -> Bool {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned && !rhs.isPinned
        }
        switch sortMode {
        case .recent:
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
        case .relevance:
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
