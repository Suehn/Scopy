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
        didSet {
            invalidatePinnedCache()
            itemIndexCacheValid = false
        }
    }

    @ObservationIgnored private var pinnedItemsCache: [ClipboardItemDTO]?
    @ObservationIgnored private var unpinnedItemsCache: [ClipboardItemDTO]?
    @ObservationIgnored private var itemIndexByID: [UUID: Int] = [:]
    @ObservationIgnored private var itemIndexCacheValid: Bool = false

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
    var searchMode: SearchMode = SettingsDTO.default.defaultSearchMode {
        didSet {
            guard !isApplyingPersistedDefaultSearchMode else {
                isApplyingPersistedDefaultSearchMode = false
                return
            }
            followsPersistedDefaultSearchMode = false
        }
    }
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
    var searchCoverage: SearchCoverage = .complete

    var performanceSummary: PerformanceSummary?

    var searchCoverageHint: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            return nil
        case .stagedRefine:
            return "首屏为预筛结果，正在全量校准…（排序/漏项可能会更新）"
        case .recentOnly(let limit):
            switch searchMode {
            case .exact:
                return "Exact 短词（≤2）仅搜索最近 \(limit) 条。输入 ≥3 字符或切换到 Fuzzy+ / Fuzzy。"
            case .regex:
                return "Regex 仅搜索最近 \(limit) 条。需要全量搜索时，请改用 Exact（≥3 字符）或 Fuzzy+。"
            case .fuzzy, .fuzzyPlus:
                return "当前仅搜索最近 \(limit) 条。"
            }
        }
    }

    var primarySearchStatusLabel: String {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return searchModeDisplayName(searchMode) }

        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            return searchModeDisplayName(searchMode)
        case .stagedRefine:
            return "Calibrating"
        case .recentOnly(let limit):
            return "Recent \(limit)"
        }
    }

    var searchStatusSummary: String {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = searchModeDisplayName(searchMode)
        guard !trimmed.isEmpty else { return "Mode: \(mode)" }

        let coverage: String
        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            coverage = "Complete"
        case .stagedRefine:
            coverage = "Staged"
        case .recentOnly(let limit):
            coverage = "Recent \(limit)"
        }

        return "Mode: \(mode) · Coverage: \(coverage) · Sort: \(searchSortDisplayName(for: trimmed))"
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var recentAppsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var persistedDefaultSearchMode: SearchMode = SettingsDTO.default.defaultSearchMode
    @ObservationIgnored private var followsPersistedDefaultSearchMode: Bool = true
    @ObservationIgnored private var isApplyingPersistedDefaultSearchMode: Bool = false

    @ObservationIgnored private var lastLoadedAt: Date = .distantPast
    @ObservationIgnored private let ftsSortModeDefaultsKey = "Scopy.FTSSortMode"

    var ftsSortMode: SearchSortMode = .relevance

    // MARK: - Init

    init(service: ClipboardServiceProtocol, settingsViewModel: SettingsViewModel) {
        self.service = service
        self.settingsViewModel = settingsViewModel
        self.persistedDefaultSearchMode = SettingsDTO.default.defaultSearchMode

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

            if didMatchCurrentFilters {
                _ = insertOrMoveItemToFront(item)
                prewarmDisplayText(for: [item])
            } else {
                _ = removeItem(withID: item.id)
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
            guard let index = indexOfItem(withID: itemID) else { return }
            let existing = items[index]
            guard existing.thumbnailPath != thumbnailPath else { return }

            let updated = ClipboardItemDTO(
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
            setItemIfChanged(at: index, to: updated)
        case .itemUpdated(let item):
            if !searchQuery.isEmpty {
                if let index = indexOfItem(withID: item.id) {
                    setItemIfChanged(at: index, to: item)
                    prewarmDisplayText(for: [item])
                }
                return
            }

            let didMatchCurrentFilters = matchesCurrentFilters(item)
            if didMatchCurrentFilters {
                _ = insertOrMoveItemToFront(item)
                prewarmDisplayText(for: [item])
            } else {
                _ = removeItem(withID: item.id)
            }

            loadedCount = items.count
            if totalCount >= 0 {
                canLoadMore = loadedCount < totalCount
            }
        case .itemContentUpdated(let item):
            guard let index = indexOfItem(withID: item.id) else { return }
            let existing = items[index]
            if existing.thumbnailPath != item.thumbnailPath, let oldPath = existing.thumbnailPath {
                ThumbnailCache.shared.remove(path: oldPath)
            }
            setItemIfChanged(at: index, to: item)
            prewarmDisplayText(for: [item])
        case .itemDeleted(let id):
            let wasPresent = removeItem(withID: id)

            loadedCount = items.count
            if totalCount >= 0 {
                if isUnfilteredList || wasPresent {
                    totalCount = max(0, totalCount - 1)
                }
                canLoadMore = loadedCount < totalCount
            }
        case .itemPinned(let id):
            if let index = indexOfItem(withID: id) {
                let updated = items[index].withPinned(true)
                setItemIfChanged(at: index, to: updated)
            }
        case .itemUnpinned(let id):
            if let index = indexOfItem(withID: id) {
                let updated = items[index].withPinned(false)
                setItemIfChanged(at: index, to: updated)
            }
        case .itemsCleared:
            await load()
        case .settingsChanged:
            break
        }
    }

    // MARK: - Settings Synchronization

    func applySettings(_ settings: SettingsDTO) {
        persistedDefaultSearchMode = settings.defaultSearchMode
        guard followsPersistedDefaultSearchMode else { return }
        isApplyingPersistedDefaultSearchMode = true
        searchMode = settings.defaultSearchMode
        followsPersistedDefaultSearchMode = true
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
            searchCoverage = .complete
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
                    if searchCoverage.isStagedRefine,
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
                        searchCoverage = result.coverage
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
                    searchCoverage = result.coverage
                } else {
                    let moreItems = try await service.fetchRecent(limit: 100, offset: loadedCount)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    items.append(contentsOf: moreItems)
                    prewarmDisplayText(for: moreItems)
                    loadedCount = items.count
                    canLoadMore = loadedCount < totalCount
                    searchCoverage = .complete
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
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let debounceNs = effectiveSearchDebounceNs(for: query)
            try? await Task.sleep(nanoseconds: debounceNs)
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
                searchCoverage = result.coverage

                if (searchMode == .fuzzy || searchMode == .fuzzyPlus),
                   result.coverage.isStagedRefine,
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
                            searchCoverage = refined.coverage
                        } catch {
                            ScopyLog.app.warning("Refine search failed: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await PerformanceMetrics.shared.recordSearchLatency(elapsedMs)
                performanceSummary = await PerformanceMetrics.shared.getSummary()
            } catch {
                searchCoverage = .complete
                ScopyLog.app.error("Search failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func effectiveSearchCoverage(for trimmedQuery: String) -> SearchCoverage {
        switch searchMode {
        case .exact where trimmedQuery.count <= 2:
            return .recentOnly(limit: 2000)
        case .regex:
            return .recentOnly(limit: 2000)
        case .exact, .fuzzy, .fuzzyPlus:
            return searchCoverage
        }
    }

    private func searchModeDisplayName(_ mode: SearchMode) -> String {
        switch mode {
        case .exact:
            return "Exact"
        case .fuzzy:
            return "Fuzzy"
        case .fuzzyPlus:
            return "Fuzzy+"
        case .regex:
            return "Regex"
        }
    }

    private func searchSortDisplayName(for trimmedQuery: String) -> String {
        if isFTSSortApplicable(for: trimmedQuery) {
            switch ftsSortMode {
            case .relevance:
                return "Relevance"
            case .recent:
                return "Recent"
            }
        }

        switch searchMode {
        case .regex:
            return "Recent"
        case .exact where trimmedQuery.count <= 2:
            return "Recent"
        case .exact, .fuzzy, .fuzzyPlus:
            return "Recent"
        }
    }

    private func isFTSSortApplicable(for trimmedQuery: String) -> Bool {
        switch searchMode {
        case .exact:
            return trimmedQuery.count >= 3
        case .fuzzy, .fuzzyPlus:
            return !trimmedQuery.isEmpty
        case .regex:
            return false
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

    func selectOptimizedForCodex(_ item: ClipboardItemDTO) async {
        do {
            try await service.copyToClipboardOptimizedForCodex(itemID: item.id)
            closePanelHandler?()
        } catch {
            ScopyLog.app.error("Codex-optimized copy failed: \(error.localizedDescription, privacy: .private)")
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
           let currentIndex = indexOfItem(withID: currentID),
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
           let currentIndex = indexOfItem(withID: currentID),
           currentIndex > 0 {
            selectedID = items[currentIndex - 1].id
        } else {
            selectedID = items.last?.id
        }
    }

    func deleteSelectedItem() async {
        guard let id = selectedID else { return }
        guard let index = indexOfItem(withID: id) else { return }

        let nextID: UUID?
        if index < items.count - 1 {
            nextID = items[index + 1].id
        } else if index > 0 {
            nextID = items[index - 1].id
        } else {
            nextID = nil
        }

        await delete(items[index])

        selectedID = nextID
        lastSelectionSource = .programmatic
    }

    func selectCurrent() async {
        if let selectedID,
           let index = indexOfItem(withID: selectedID) {
            await select(items[index])
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

    private func rebuildItemIndexCacheIfNeeded() {
        guard PerfFeatureFlags.historyIndexingEnabled else { return }
        guard !itemIndexCacheValid else { return }
        var rebuilt: [UUID: Int] = [:]
        rebuilt.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            rebuilt[item.id] = index
        }
        itemIndexByID = rebuilt
        itemIndexCacheValid = true
    }

    private func indexOfItem(withID id: UUID) -> Int? {
        guard PerfFeatureFlags.historyIndexingEnabled else {
            return items.firstIndex(where: { $0.id == id })
        }
        rebuildItemIndexCacheIfNeeded()
        return itemIndexByID[id]
    }

    @discardableResult
    private func setItemIfChanged(at index: Int, to value: ClipboardItemDTO) -> Bool {
        guard items.indices.contains(index) else { return false }
        guard items[index] != value else { return false }
        items[index] = value
        return true
    }

    @discardableResult
    private func removeItem(withID id: UUID) -> Bool {
        guard let index = indexOfItem(withID: id) else { return false }
        items.remove(at: index)
        return true
    }

    @discardableResult
    private func insertOrMoveItemToFront(_ item: ClipboardItemDTO) -> Bool {
        if let existingIndex = indexOfItem(withID: item.id) {
            if existingIndex == 0 {
                return setItemIfChanged(at: existingIndex, to: item)
            }
            items.remove(at: existingIndex)
        }
        items.insert(item, at: 0)
        return true
    }

    private func effectiveSearchDebounceNs(for query: String) -> UInt64 {
        guard PerfFeatureFlags.shortQueryDebounceEnabled else {
            return timing.searchDebounceNs
        }
        if query.count <= 2 {
            return max(timing.searchDebounceNs, 16_000_000)
        }
        return timing.searchDebounceNs
    }

    private func cancelTask(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}
