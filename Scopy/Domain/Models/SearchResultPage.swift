import Foundation

/// 搜索结果页 - 对应 v0.md 中的 SearchResultPage
public struct SearchResultPage: Sendable {
    public let items: [ClipboardItemDTO]
    public let total: Int
    public let hasMore: Bool
    /// Whether this page is a best-effort / partial result set (e.g. cache-limited prefilter).
    ///
    /// Notes:
    /// - UI may choose to refine with a stronger query when `isPrefilter` is true.
    public let isPrefilter: Bool

    public init(items: [ClipboardItemDTO], total: Int, hasMore: Bool, isPrefilter: Bool = false) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
        self.isPrefilter = isPrefilter
    }
}
