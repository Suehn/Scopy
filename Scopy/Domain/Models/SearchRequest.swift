import Foundation

/// 搜索请求 - 对应 v0.md 中的 SearchRequest
/// v0.22: 添加 typeFilters 支持多类型过滤（如 Rich Text = rtf + html）
public struct SearchRequest: Sendable {
    public let query: String
    public let mode: SearchMode
    public let sortMode: SearchSortMode
    public let appFilter: String?
    public let typeFilter: ClipboardItemType?
    /// v0.22: 多类型过滤，优先于 typeFilter
    public let typeFilters: Set<ClipboardItemType>?
    /// v0.29: 渐进搜索 - 是否强制使用全量 fuzzy（禁用首屏预筛）
    public let forceFullFuzzy: Bool
    public let limit: Int
    public let offset: Int

    public init(
        query: String,
        mode: SearchMode = SettingsDTO.default.defaultSearchMode,
        sortMode: SearchSortMode = .relevance,
        appFilter: String? = nil,
        typeFilter: ClipboardItemType? = nil,
        typeFilters: Set<ClipboardItemType>? = nil,
        forceFullFuzzy: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.query = query
        self.mode = mode
        self.sortMode = sortMode
        self.appFilter = appFilter
        self.typeFilter = typeFilter
        self.typeFilters = typeFilters
        self.forceFullFuzzy = forceFullFuzzy
        self.limit = limit
        self.offset = offset
    }
}
