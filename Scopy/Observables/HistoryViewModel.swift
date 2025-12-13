import Foundation
import Observation

@Observable
@MainActor
final class HistoryViewModel {
    // MARK: - Properties

    @ObservationIgnored private var service: ClipboardServiceProtocol
    @ObservationIgnored private let settingsViewModel: SettingsViewModel

    @ObservationIgnored var closePanelHandler: (() -> Void)?

    var items: [ClipboardItemDTO] = [] {
        didSet { invalidatePinnedCache() }
    }

    @ObservationIgnored private var pinnedItemsCache: [ClipboardItemDTO]?
    @ObservationIgnored private var unpinnedItemsCache: [ClipboardItemDTO]?

    var pinnedItems: [ClipboardItemDTO] {
        if let cached = pinnedItemsCache { return cached }
        let result = items.filter { $0.isPinned }
        pinnedItemsCache = result
        return result
    }

    var unpinnedItems: [ClipboardItemDTO] {
        if let cached = unpinnedItemsCache { return cached }
        let result = items.filter { !$0.isPinned }
        unpinnedItemsCache = result
        return result
    }

    var searchQuery: String = ""
    var searchMode: SearchMode = SettingsDTO.default.defaultSearchMode
    var isLoading: Bool = false
    var selectedID: UUID?

    var isPinnedCollapsed: Bool = false

    var appFilter: String?
    var typeFilter: ClipboardItemType?
    var typeFilters: Set<ClipboardItemType>?
    var recentApps: [String] = []

    var hasActiveFilters: Bool {
        !searchQuery.isEmpty || appFilter != nil || typeFilter != nil || typeFilters != nil
    }

    var lastSelectionSource: SelectionSource = .programmatic

    var isScrolling: Bool = false
    @ObservationIgnored private var scrollEndTask: Task<Void, Never>?

    private var searchVersion: Int = 0

    var canLoadMore: Bool = false
    var loadedCount: Int = 0
    var totalCount: Int = 0

    var performanceSummary: PerformanceSummary?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var recentAppsRefreshTask: Task<Void, Never>?

    // MARK: - Init

    init(service: ClipboardServiceProtocol, settingsViewModel: SettingsViewModel) {
        self.service = service
        self.settingsViewModel = settingsViewModel
    }

    func updateService(_ service: ClipboardServiceProtocol) {
        self.service = service
    }

    func stop() {
        searchTask?.cancel()
        loadMoreTask?.cancel()
        refineTask?.cancel()
        scrollEndTask?.cancel()
        recentAppsRefreshTask?.cancel()

        searchTask = nil
        loadMoreTask = nil
        refineTask = nil
        scrollEndTask = nil
        recentAppsRefreshTask = nil
    }

    // MARK: - Event Handling

    func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem(let item):
            let wasExisting = items.contains(where: { $0.id == item.id })
            items.removeAll { $0.id == item.id }

            if matchesCurrentFilters(item) {
                items.insert(item, at: 0)
            }
            invalidatePinnedCache()

            if !wasExisting {
                totalCount += 1
            }

            if let bundleID = item.appBundleID, !recentApps.contains(bundleID) {
                scheduleRecentAppsRefresh()
            }
        case .itemUpdated(let item):
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            invalidatePinnedCache()
        case .itemDeleted(let id):
            items.removeAll { $0.id == id }
            invalidatePinnedCache()
            totalCount -= 1
        case .itemPinned(let id):
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withPinned(true)
                invalidatePinnedCache()
            }
        case .itemUnpinned(let id):
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withPinned(false)
                invalidatePinnedCache()
            }
        case .itemsCleared:
            await load()
        case .settingsChanged:
            break
        }
    }

    // MARK: - Settings Synchronization

    func applySettings(_ settings: SettingsDTO) {
        searchMode = settings.defaultSearchMode
    }

    // MARK: - Apps / Filters

    func loadRecentApps() async {
        do {
            recentApps = try await service.getRecentApps(limit: 10)
            preloadAppIcons()
        } catch {
            ScopyLog.app.error("Failed to load recent apps: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleRecentAppsRefresh() {
        recentAppsRefreshTask?.cancel()
        recentAppsRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await loadRecentApps()
        }
    }

    private func preloadAppIcons() {
        let appsToPreload = recentApps
        Task.detached(priority: .background) {
            for bundleID in appsToPreload {
                await IconService.shared.preloadIcon(bundleID: bundleID)
            }
        }
    }

    private func matchesCurrentFilters(_ item: ClipboardItemDTO) -> Bool {
        if let typeFilters = typeFilters, !typeFilters.contains(item.type) {
            return false
        }
        if typeFilters == nil, let typeFilter = typeFilter, item.type != typeFilter {
            return false
        }
        if let appFilter = appFilter, item.appBundleID != appFilter {
            return false
        }
        if !searchQuery.isEmpty {
            return false
        }
        return true
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let startTime = CFAbsoluteTimeGetCurrent()

            let fetchedItems = try await service.fetchRecent(limit: 50, offset: 0)
            items = fetchedItems
            loadedCount = fetchedItems.count

            let stats = try await service.getStorageStats()
            totalCount = stats.itemCount
            canLoadMore = loadedCount < totalCount

            settingsViewModel.storageStats = stats
            await settingsViewModel.refreshDiskSizeIfNeeded()

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            await PerformanceMetrics.shared.recordLoadLatency(elapsedMs)
            performanceSummary = await PerformanceMetrics.shared.getSummary()
        } catch {
            ScopyLog.app.error("Failed to load items: \(error.localizedDescription, privacy: .public)")
        }
    }

    func onScroll() {
        isScrolling = true
        scrollEndTask?.cancel()
        scrollEndTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }

    func loadMore() async {
        loadMoreTask?.cancel()

        loadMoreTask = Task {
            guard !Task.isCancelled else { return }
            guard canLoadMore, !isLoading else { return }

            let currentVersion = searchVersion

            isLoading = true
            defer { isLoading = false }

            do {
                if !searchQuery.isEmpty || appFilter != nil || typeFilter != nil || typeFilters != nil {
                    // When current result is prefilter (total = -1), force full fuzzy before paging.
                    if totalCount == -1,
                       (searchMode == .fuzzy || searchMode == .fuzzyPlus) {
                        let expectedLimit = loadedCount + 50
                        let request = SearchRequest(
                            query: searchQuery,
                            mode: searchMode,
                            appFilter: appFilter,
                            typeFilter: typeFilter,
                            typeFilters: typeFilters,
                            forceFullFuzzy: true,
                            limit: expectedLimit,
                            offset: 0
                        )
                        let result = try await service.search(query: request)
                        guard !Task.isCancelled, currentVersion == searchVersion else { return }
                        items = result.items
                        loadedCount = result.items.count
                        totalCount = result.total
                        canLoadMore = result.hasMore
                        return
                    }

                    let request = SearchRequest(
                        query: searchQuery,
                        mode: searchMode,
                        appFilter: appFilter,
                        typeFilter: typeFilter,
                        typeFilters: typeFilters,
                        limit: 50,
                        offset: loadedCount
                    )
                    let result = try await service.search(query: request)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }

                    items.append(contentsOf: result.items)
                    invalidatePinnedCache()
                    loadedCount = items.count
                    totalCount = result.total
                    canLoadMore = result.hasMore
                } else {
                    let moreItems = try await service.fetchRecent(limit: 100, offset: loadedCount)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    items.append(contentsOf: moreItems)
                    invalidatePinnedCache()
                    loadedCount = items.count
                    canLoadMore = loadedCount < totalCount
                }
            } catch {
                if !Task.isCancelled {
                    ScopyLog.app.error("Failed to load more: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        await loadMoreTask?.value
    }

    // MARK: - Search

    func search() {
        searchTask?.cancel()
        refineTask?.cancel()
        refineTask = nil

        if searchQuery.isEmpty && appFilter == nil && typeFilter == nil && typeFilters == nil {
            Task { await load() }
            return
        }

        searchVersion += 1
        let currentVersion = searchVersion

        loadMoreTask?.cancel()
        loadMoreTask = nil

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            guard currentVersion == searchVersion else { return }

            isLoading = true
            defer { isLoading = false }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()

                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    appFilter: appFilter,
                    typeFilter: typeFilter,
                    typeFilters: typeFilters,
                    limit: 50,
                    offset: 0
                )
                let result = try await service.search(query: request)
                guard !Task.isCancelled, currentVersion == searchVersion else { return }

                items = result.items
                totalCount = result.total
                loadedCount = result.items.count
                canLoadMore = result.hasMore

                if (searchMode == .fuzzy || searchMode == .fuzzyPlus),
                   result.total == -1,
                   loadedCount <= 50 {
                    let refineQuery = searchQuery
                    let refineMode = searchMode
                    let refineAppFilter = appFilter
                    let refineTypeFilter = typeFilter
                    let refineTypeFilters = typeFilters
                    let refineVersion = currentVersion

                    refineTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled, refineVersion == searchVersion else { return }

                        let refineRequest = SearchRequest(
                            query: refineQuery,
                            mode: refineMode,
                            appFilter: refineAppFilter,
                            typeFilter: refineTypeFilter,
                            typeFilters: refineTypeFilters,
                            forceFullFuzzy: true,
                            limit: 50,
                            offset: 0
                        )

                        do {
                            let refined = try await service.search(query: refineRequest)
                            guard !Task.isCancelled, refineVersion == searchVersion else { return }

                            guard loadedCount <= 50 else { return }

                            items = refined.items
                            totalCount = refined.total
                            loadedCount = refined.items.count
                            canLoadMore = refined.hasMore
                        } catch {
                            ScopyLog.app.warning("Refine search failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await PerformanceMetrics.shared.recordSearchLatency(elapsedMs)
                performanceSummary = await PerformanceMetrics.shared.getSummary()
            } catch {
                ScopyLog.app.error("Search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Actions

    func select(_ item: ClipboardItemDTO) async {
        do {
            try await service.copyToClipboard(itemID: item.id)
            closePanelHandler?()
        } catch {
            ScopyLog.app.error("Copy failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePin(_ item: ClipboardItemDTO) async {
        do {
            if item.isPinned {
                try await service.unpin(itemID: item.id)
            } else {
                try await service.pin(itemID: item.id)
            }
        } catch {
            ScopyLog.app.error("Pin toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ item: ClipboardItemDTO) async {
        do {
            try await service.delete(itemID: item.id)
            items.removeAll { $0.id == item.id }
            invalidatePinnedCache()
        } catch {
            ScopyLog.app.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearAll() async {
        do {
            try await service.clearAll()
            await load()
        } catch {
            ScopyLog.app.error("Clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        try await service.getImageData(itemID: itemID)
    }

    // MARK: - Keyboard Navigation

    func highlightNext() {
        guard !items.isEmpty else { return }
        lastSelectionSource = .keyboard
        if let currentID = selectedID,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }),
           currentIndex < items.count - 1 {
            selectedID = items[currentIndex + 1].id
        } else {
            selectedID = items.first?.id
        }
    }

    func highlightPrevious() {
        guard !items.isEmpty else { return }
        lastSelectionSource = .keyboard
        if let currentID = selectedID,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }),
           currentIndex > 0 {
            selectedID = items[currentIndex - 1].id
        } else {
            selectedID = items.last?.id
        }
    }

    func deleteSelectedItem() async {
        guard let id = selectedID else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        let nextID: UUID?
        if index < items.count - 1 {
            nextID = items[index + 1].id
        } else if index > 0 {
            nextID = items[index - 1].id
        } else {
            nextID = nil
        }

        if let item = items.first(where: { $0.id == id }) {
            await delete(item)
        }

        selectedID = nextID
        lastSelectionSource = .programmatic
    }

    func selectCurrent() async {
        if let selectedID,
           let item = items.first(where: { $0.id == selectedID }) {
            await select(item)
        }
    }

    // MARK: - Private

    private func invalidatePinnedCache() {
        pinnedItemsCache = nil
        unpinnedItemsCache = nil
    }
}

