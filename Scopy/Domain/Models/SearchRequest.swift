import Foundation

/// One search: query, mode, sort, filters, and page.
public struct SearchRequest: Sendable {
    public let query: String
    public let mode: SearchMode
    public let sortMode: SearchSortMode
    public let appFilter: String?
    public let typeFilter: ClipboardItemType?
    /// Several item types at once (Rich Text is rtf + html); wins over `typeFilter`.
    public let typeFilters: Set<ClipboardItemType>?
    /// Staged search refine: skip the first-page prefilter and run the full fuzzy search.
    public let forceFullFuzzy: Bool
    public let limit: Int
    public let offset: Int

    public var hasSemanticQuery: Bool {
        switch mode {
        case .regex:
            return !query.isEmpty
        case .exact, .fuzzy, .fuzzyPlus:
            return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

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
