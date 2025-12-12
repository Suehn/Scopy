import Foundation

/// 搜索请求 - 对应 v0.md 中的 SearchRequest
/// v0.22: 添加 typeFilters 支持多类型过滤（如 Rich Text = rtf + html）
struct SearchRequest: Sendable {
    let query: String
    let mode: SearchMode
    let appFilter: String?
    let typeFilter: ClipboardItemType?
    /// v0.22: 多类型过滤，优先于 typeFilter
    let typeFilters: Set<ClipboardItemType>?
    /// v0.29: 渐进搜索 - 是否强制使用全量 fuzzy（禁用首屏预筛）
    let forceFullFuzzy: Bool
    let limit: Int
    let offset: Int

    init(
        query: String,
        mode: SearchMode = SettingsDTO.default.defaultSearchMode,
        appFilter: String? = nil,
        typeFilter: ClipboardItemType? = nil,
        typeFilters: Set<ClipboardItemType>? = nil,
        forceFullFuzzy: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.query = query
        self.mode = mode
        self.appFilter = appFilter
        self.typeFilter = typeFilter
        self.typeFilters = typeFilters
        self.forceFullFuzzy = forceFullFuzzy
        self.limit = limit
        self.offset = offset
    }
}

