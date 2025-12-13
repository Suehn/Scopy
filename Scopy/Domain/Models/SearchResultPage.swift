import Foundation

/// 搜索结果页 - 对应 v0.md 中的 SearchResultPage
public struct SearchResultPage: Sendable {
    public let items: [ClipboardItemDTO]
    public let total: Int
    public let hasMore: Bool

    public init(items: [ClipboardItemDTO], total: Int, hasMore: Bool) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
    }
}
