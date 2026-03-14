import Foundation
import ScopyKit

@MainActor
extension AppState {
    var items: [ClipboardItemDTO] {
        get { historyViewModel.items }
        set { historyViewModel.items = newValue }
    }

    var pinnedItems: [ClipboardItemDTO] { historyViewModel.pinnedItems }
    var unpinnedItems: [ClipboardItemDTO] { historyViewModel.unpinnedItems }

    var searchQuery: String {
        get { historyViewModel.searchQuery }
        set { historyViewModel.searchQuery = newValue }
    }

    var searchMode: SearchMode {
        get { historyViewModel.searchMode }
        set { historyViewModel.searchMode = newValue }
    }

    var isLoading: Bool {
        get { historyViewModel.isLoading }
        set { historyViewModel.isLoading = newValue }
    }

    var selectedID: UUID? {
        get { historyViewModel.selectedID }
        set { historyViewModel.selectedID = newValue }
    }

    var isPinnedCollapsed: Bool {
        get { historyViewModel.isPinnedCollapsed }
        set { historyViewModel.isPinnedCollapsed = newValue }
    }

    var appFilter: String? {
        get { historyViewModel.appFilter }
        set { historyViewModel.appFilter = newValue }
    }

    var typeFilter: ClipboardItemType? {
        get { historyViewModel.typeFilter }
        set { historyViewModel.typeFilter = newValue }
    }

    var typeFilters: Set<ClipboardItemType>? {
        get { historyViewModel.typeFilters }
        set { historyViewModel.typeFilters = newValue }
    }

    var recentApps: [String] {
        get { historyViewModel.recentApps }
        set { historyViewModel.recentApps = newValue }
    }

    var hasActiveFilters: Bool { historyViewModel.hasActiveFilters }

    var lastSelectionSource: SelectionSource {
        get { historyViewModel.lastSelectionSource }
        set { historyViewModel.lastSelectionSource = newValue }
    }

    var isScrolling: Bool {
        get { historyViewModel.isScrolling }
        set { historyViewModel.isScrolling = newValue }
    }

    var canLoadMore: Bool {
        get { historyViewModel.canLoadMore }
        set { historyViewModel.canLoadMore = newValue }
    }

    var loadedCount: Int {
        get { historyViewModel.loadedCount }
        set { historyViewModel.loadedCount = newValue }
    }

    var totalCount: Int {
        get { historyViewModel.totalCount }
        set { historyViewModel.totalCount = newValue }
    }

    var performanceSummary: PerformanceSummary? {
        get { historyViewModel.performanceSummary }
        set { historyViewModel.performanceSummary = newValue }
    }

    var settings: SettingsDTO {
        get { settingsViewModel.settings }
        set { settingsViewModel.settings = newValue }
    }

    var storageStats: (itemCount: Int, sizeBytes: Int) {
        get { settingsViewModel.storageStats }
        set { settingsViewModel.storageStats = newValue }
    }

    var diskSizeBytes: Int {
        get { settingsViewModel.diskSizeBytes }
        set { settingsViewModel.diskSizeBytes = newValue }
    }

    var storageSizeText: String { settingsViewModel.storageSizeText }

    func loadSettings() async {
        await settingsViewModel.loadSettings()
        historyViewModel.applySettings(settingsViewModel.settings)
    }

    func loadRecentApps() async {
        await historyViewModel.loadRecentApps()
    }

    func load() async {
        await historyViewModel.load()
    }

    func scrollDidStart() {
        historyViewModel.scrollDidStart()
    }

    func scrollDidEnd() {
        historyViewModel.scrollDidEnd()
    }

    func loadMore() async {
        await historyViewModel.loadMore()
    }

    func search() {
        historyViewModel.search()
    }

    func select(_ item: ClipboardItemDTO) async {
        await historyViewModel.select(item)
    }

    func togglePin(_ item: ClipboardItemDTO) async {
        await historyViewModel.togglePin(item)
    }

    func delete(_ item: ClipboardItemDTO) async {
        await historyViewModel.delete(item)
    }

    func clearAll() async {
        await historyViewModel.clearAll()
    }

    func highlightNext() {
        historyViewModel.highlightNext()
    }

    func highlightPrevious() {
        historyViewModel.highlightPrevious()
    }

    func deleteSelectedItem() async {
        await historyViewModel.deleteSelectedItem()
    }

    func selectCurrent() async {
        await historyViewModel.selectCurrent()
    }
}
