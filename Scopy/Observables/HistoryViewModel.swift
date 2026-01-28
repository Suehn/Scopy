import Foundation
import Observation
import ScopyKit
import ScopyUISupport

@Observable
@MainActor
final class HistoryViewModel {
    struct Timing: Sendable {
        var searchDebounceNs: UInt64
        var refineShortQueryDelayNs: UInt64
        var refineLongQueryDelayNs: UInt64
        var recentAppsRefreshDelayNs: UInt64

        static let production = Timing(
            // v0.29+: 更快的首屏反馈（10ms 级）
            searchDebounceNs: 0,
            // v0.57+: 长词全量校准足够快，refine 立即执行；短词保留极短 delay 避免抖动
            refineShortQueryDelayNs: 10_000_000,
            refineLongQueryDelayNs: 0,
            recentAppsRefreshDelayNs: 500_000_000
        )

        static let tests = Timing(
            searchDebounceNs: 20_000_000,
            refineShortQueryDelayNs: 40_000_000,
            refineLongQueryDelayNs: 40_000_000,
            recentAppsRefreshDelayNs: 20_000_000
        )
    }

    // MARK: - Properties

    @ObservationIgnored private var service: ClipboardServiceProtocol
    @ObservationIgnored private let settingsViewModel: SettingsViewModel
    @ObservationIgnored private var timing: Timing = .production

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

    private var isUnfilteredList: Bool {
        !hasActiveFilters
    }

    var lastSelectionSource: SelectionSource = .programmatic

    var isScrolling: Bool = false

    private var searchVersion: Int = 0

    var canLoadMore: Bool = false
    var loadedCount: Int = 0
    var totalCount: Int = 0
    var isPrefilterResult: Bool = false

    var performanceSummary: PerformanceSummary?

    var cacheLimitedSearchHint: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        switch searchMode {
        case .exact:
            guard !trimmed.isEmpty, trimmed.count <= 2 else { return nil }
            return "Exact 短词（≤2）仅搜索最近 2000 条。输入 ≥3 字符或切换到 Fuzzy/Fuzzy+ 以全量搜索。"
        case .regex:
            guard !trimmed.isEmpty else { return nil }
            return "Regex 仅搜索最近 2000 条（性能考虑）。如需全量搜索，请切换到 Exact（≥3 字符）或 Fuzzy/Fuzzy+。"
        case .fuzzy, .fuzzyPlus:
            return nil
        }
    }

    var progressiveSearchHint: String? {
        guard isPrefilterResult else { return nil }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch searchMode {
        case .fuzzy, .fuzzyPlus:
            return "首屏为预筛结果，正在全量校准…（排序/漏项可能会更新）"
        case .exact, .regex:
            return nil
        }
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var recentAppsRefreshTask: Task<Void, Never>?

    @ObservationIgnored private var lastLoadedAt: Date = .distantPast
    @ObservationIgnored private let ftsSortModeDefaultsKey = "Scopy.FTSSortMode"

    var ftsSortMode: SearchSortMode = .relevance

    // MARK: - Init

    init(service: ClipboardServiceProtocol, settingsViewModel: SettingsViewModel) {
        self.service = service
        self.settingsViewModel = settingsViewModel

        if let raw = UserDefaults.standard.string(forKey: ftsSortModeDefaultsKey),
           let mode = SearchSortMode(rawValue: raw) {
            ftsSortMode = mode
        }
    }

    func configureTiming(_ timing: Timing) {
        self.timing = timing
    }

    func updateService(_ service: ClipboardServiceProtocol) {
        self.service = service
    }

    func stop() {
        cancelTask(&searchTask)
        cancelTask(&loadMoreTask)
        cancelTask(&refineTask)
        cancelTask(&recentAppsRefreshTask)
    }

    // MARK: - Event Handling

    func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem(let item):
            let didMatchCurrentFilters = matchesCurrentFilters(item)

            items.removeAll { $0.id == item.id }

            if didMatchCurrentFilters {
                items.insert(item, at: 0)
                prewarmDisplayText(for: [item])
            }

            loadedCount = items.count
            if didMatchCurrentFilters, totalCount >= 0 {
                totalCount += 1
            } else if isUnfilteredList, totalCount >= 0 {
                totalCount += 1
            }
            if totalCount >= 0 {
                canLoadMore = loadedCount < totalCount
            }

            if let bundleID = item.appBundleID, !recentApps.contains(bundleID) {
                scheduleRecentAppsRefresh()
            }
        case .thumbnailUpdated(let itemID, let thumbnailPath):
            ThumbnailCache.shared.remove(path: thumbnailPath)
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            let existing = items[index]
            guard existing.thumbnailPath != thumbnailPath else { return }

            items[index] = ClipboardItemDTO(
                id: existing.id,
                type: existing.type,
                contentHash: existing.contentHash,
                plainText: existing.plainText,
                note: existing.note,
                appBundleID: existing.appBundleID,
                createdAt: existing.createdAt,
                lastUsedAt: existing.lastUsedAt,
                isPinned: existing.isPinned,
                sizeBytes: existing.sizeBytes,
                fileSizeBytes: existing.fileSizeBytes,
                thumbnailPath: thumbnailPath,
                storageRef: existing.storageRef
            )
        case .itemUpdated(let item):
            if !searchQuery.isEmpty {
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                    prewarmDisplayText(for: [item])
                }
                return
            }

            let didMatchCurrentFilters = matchesCurrentFilters(item)
            items.removeAll { $0.id == item.id }
            if didMatchCurrentFilters {
                items.insert(item, at: 0)
                prewarmDisplayText(for: [item])
            }

            loadedCount = items.count
            if totalCount >= 0 {
                canLoadMore = loadedCount < totalCount
            }
        case .itemContentUpdated(let item):
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            let existing = items[index]
            if existing.thumbnailPath != item.thumbnailPath, let oldPath = existing.thumbnailPath {
                ThumbnailCache.shared.remove(path: oldPath)
            }
            items[index] = item
            prewarmDisplayText(for: [item])
        case .itemDeleted(let id):
            let previousCount = items.count
            items.removeAll { $0.id == id }
            let wasPresent = items.count != previousCount

            loadedCount = items.count
            if totalCount >= 0 {
                if isUnfilteredList || wasPresent {
                    totalCount = max(0, totalCount - 1)
                }
                canLoadMore = loadedCount < totalCount
            }
        case .itemPinned(let id):
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withPinned(true)
            }
        case .itemUnpinned(let id):
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withPinned(false)
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
            ScopyLog.app.error("Failed to load recent apps: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func scheduleRecentAppsRefresh() {
        recentAppsRefreshTask?.cancel()
        recentAppsRefreshTask = Task {
            try? await Task.sleep(nanoseconds: timing.recentAppsRefreshDelayNs)
            guard !Task.isCancelled else { return }
            await loadRecentApps()
        }
    }

    private func preloadAppIcons() {
        let appsToPreload = recentApps
        Task { @MainActor in
            for bundleID in appsToPreload {
                IconService.shared.preloadIcon(bundleID: bundleID)
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
            prewarmDisplayText(for: fetchedItems)
            loadedCount = fetchedItems.count
            isPrefilterResult = false
            lastLoadedAt = Date()

            // Load latency should reflect "first screen ready" rather than unrelated background work.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            await PerformanceMetrics.shared.recordLoadLatency(elapsedMs)
            performanceSummary = await PerformanceMetrics.shared.getSummary()

            let stats = try await service.getStorageStats()
            totalCount = stats.itemCount
            canLoadMore = loadedCount < totalCount

            settingsViewModel.storageStats = stats
            await settingsViewModel.refreshDiskSizeIfNeeded()
            settingsViewModel.syncExternalImageSizeBytesFromDiskIfNeeded()
        } catch {
            ScopyLog.app.error("Failed to load items: \(error.localizedDescription, privacy: .private)")
        }
    }

    func loadIfStale(minIntervalSeconds: TimeInterval = 0.5) async {
        guard !isLoading else { return }
        guard items.isEmpty || Date().timeIntervalSince(lastLoadedAt) >= minIntervalSeconds else { return }
        await load()
    }

    func scrollDidStart() {
        guard !isScrolling else { return }
        isScrolling = true
        ScrollPerformanceProfile.shared.scrollDidStart()
    }

    func scrollDidEnd() {
        guard isScrolling else { return }
        isScrolling = false
        ScrollPerformanceProfile.shared.scrollDidEnd()
    }

    func loadMore() async {
        cancelTask(&loadMoreTask)

        loadMoreTask = Task {
            guard !Task.isCancelled else { return }
            guard canLoadMore, !isLoading else { return }

            let currentVersion = searchVersion

            isLoading = true
            defer { isLoading = false }

            do {
                if !isUnfilteredList {
                    // When current result is prefilter (total = -1), force full fuzzy before paging.
                    if isPrefilterResult,
                       (searchMode == .fuzzy || searchMode == .fuzzyPlus) {
                        let expectedLimit = loadedCount + 50
                        let request = SearchRequest(
                            query: searchQuery,
                            mode: searchMode,
                            sortMode: ftsSortMode,
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
                        prewarmDisplayText(for: result.items)
                        loadedCount = result.items.count
                        totalCount = result.total
                        canLoadMore = result.hasMore
                        isPrefilterResult = result.isPrefilter
                        return
                    }

                    let request = SearchRequest(
                        query: searchQuery,
                        mode: searchMode,
                        sortMode: ftsSortMode,
                        appFilter: appFilter,
                        typeFilter: typeFilter,
                        typeFilters: typeFilters,
                        limit: 50,
                        offset: loadedCount
                    )
                    let result = try await service.search(query: request)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }

                    items.append(contentsOf: result.items)
                    prewarmDisplayText(for: result.items)
                    loadedCount = items.count
                    totalCount = result.total
                    canLoadMore = result.hasMore
                    isPrefilterResult = result.isPrefilter
                } else {
                    let moreItems = try await service.fetchRecent(limit: 100, offset: loadedCount)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    items.append(contentsOf: moreItems)
                    prewarmDisplayText(for: moreItems)
                    loadedCount = items.count
                    canLoadMore = loadedCount < totalCount
                    isPrefilterResult = false
                }
            } catch {
                if !Task.isCancelled {
                    ScopyLog.app.error("Failed to load more: \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        await loadMoreTask?.value
    }

    // MARK: - Search

    func search() {
        cancelTask(&searchTask)
        cancelTask(&refineTask)

        searchVersion += 1
        let currentVersion = searchVersion

        cancelTask(&loadMoreTask)

        if isUnfilteredList {
            searchTask = Task {
                guard !Task.isCancelled else { return }
                guard currentVersion == searchVersion else { return }
                await load()
            }
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: timing.searchDebounceNs)
            guard !Task.isCancelled else { return }
            guard currentVersion == searchVersion else { return }

            isLoading = true
            defer { isLoading = false }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()

                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    sortMode: ftsSortMode,
                    appFilter: appFilter,
                    typeFilter: typeFilter,
                    typeFilters: typeFilters,
                    limit: 50,
                    offset: 0
                )
                let result = try await service.search(query: request)
                guard !Task.isCancelled, currentVersion == searchVersion else { return }

                items = result.items
                prewarmDisplayText(for: result.items)
                totalCount = result.total
                loadedCount = result.items.count
                canLoadMore = result.hasMore
                isPrefilterResult = result.isPrefilter

                if (searchMode == .fuzzy || searchMode == .fuzzyPlus),
                   result.isPrefilter,
                   loadedCount <= 50 {
                    let refineQuery = searchQuery
                    let refineMode = searchMode
                    let refineAppFilter = appFilter
                    let refineTypeFilter = typeFilter
                    let refineTypeFilters = typeFilters
                    let refineVersion = currentVersion

                    refineTask = Task {
                        let trimmed = refineQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        let delayNs: UInt64 = trimmed.count <= 2 ? timing.refineShortQueryDelayNs : timing.refineLongQueryDelayNs
                        try? await Task.sleep(nanoseconds: delayNs)
                        guard !Task.isCancelled, refineVersion == searchVersion else { return }

                        let refineRequest = SearchRequest(
                            query: refineQuery,
                            mode: refineMode,
                            sortMode: ftsSortMode,
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
                            prewarmDisplayText(for: refined.items)
                            totalCount = refined.total
                            loadedCount = refined.items.count
                            canLoadMore = refined.hasMore
                            isPrefilterResult = refined.isPrefilter
                        } catch {
                            ScopyLog.app.warning("Refine search failed: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await PerformanceMetrics.shared.recordSearchLatency(elapsedMs)
                performanceSummary = await PerformanceMetrics.shared.getSummary()
            } catch {
                ScopyLog.app.error("Search failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func toggleFTSSortMode() {
        ftsSortMode = ftsSortMode.toggled
        UserDefaults.standard.set(ftsSortMode.rawValue, forKey: ftsSortModeDefaultsKey)
        search()
    }

    // MARK: - Actions

    func select(_ item: ClipboardItemDTO) async {
        do {
            try await service.copyToClipboard(itemID: item.id)
            closePanelHandler?()
        } catch {
            ScopyLog.app.error("Copy failed: \(error.localizedDescription, privacy: .private)")
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
            ScopyLog.app.error("Pin toggle failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func delete(_ item: ClipboardItemDTO) async {
        do {
            try await service.delete(itemID: item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            ScopyLog.app.error("Delete failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func updateNote(_ item: ClipboardItemDTO, note: String?) async {
        do {
            try await service.updateNote(itemID: item.id, note: note)
        } catch {
            ScopyLog.app.error("Update note failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func clearAll() async {
        do {
            try await service.clearAll()
            await load()
        } catch {
            ScopyLog.app.error("Clear failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        try await service.getImageData(itemID: itemID)
    }

    func optimizeImage(_ item: ClipboardItemDTO) async -> ImageOptimizationOutcomeDTO {
        do {
            return try await service.optimizeImage(itemID: item.id)
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: item.sizeBytes,
                optimizedBytes: item.sizeBytes
            )
        }
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

    private func prewarmDisplayText(for items: [ClipboardItemDTO]) {
        guard !items.isEmpty else { return }
        ClipboardItemDisplayText.shared.prewarm(items: items)
    }

    private func cancelTask(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}
