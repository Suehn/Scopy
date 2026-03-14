import Foundation

/// 搜索结果页 - 对应 v0.md 中的 SearchResultPage
public struct SearchResultPage: Sendable {
    public let items: [ClipboardItemDTO]
    public let total: Int
    public let hasMore: Bool
    /// Whether this page is complete, staged for refine, or intentionally limited to recent history.
    public let coverage: SearchCoverage

    public var isPrefilter: Bool {
        coverage.isPrefilter
    }

    public init(
        items: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool,
        coverage: SearchCoverage = .complete
    ) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
        self.coverage = coverage
    }

    public init(items: [ClipboardItemDTO], total: Int, hasMore: Bool, isPrefilter: Bool) {
        self.init(
            items: items,
            total: total,
            hasMore: hasMore,
            coverage: isPrefilter ? .stagedRefine : .complete
        )
    }
}
