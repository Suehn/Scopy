import Foundation

/// 搜索结果页 - 对应 v0.md 中的 SearchResultPage
struct SearchResultPage: Sendable {
    let items: [ClipboardItemDTO]
    let total: Int
    let hasMore: Bool
}

