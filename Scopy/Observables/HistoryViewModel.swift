import AppKit
import Foundation
import Observation
import ScopyKit
import ScopyUISupport

struct HistoryContentRevisionReconciliationSnapshot {
    let knownRevisionsByItemID: [UUID: ClipboardItemContentRevision]
    let deletedItemIDs: Set<UUID>
    let clearGeneration: UInt64
    let clearSurvivingItemIDs: Set<UUID>
    let clearSurvivorSetIsAuthoritative: Bool
    let deletionEvictionGeneration: UInt64

    func revision(for itemID: UUID) -> ClipboardItemContentRevision? {
        knownRevisionsByItemID[itemID]
    }

    func wasDeleted(_ itemID: UUID) -> Bool {
        deletedItemIDs.contains(itemID)
    }
}

struct BoundedHistoryContentRevisionRegistry {
    private struct RevisionEntry {
        let revision: ClipboardItemContentRevision
        let isPinned: Bool
        let stamp: UInt64
    }

    private struct DeletionEntry {
        let stamp: UInt64
    }

    private let capacity: Int
    private var nextStamp: UInt64 = 0
    private var revisionsByItemID: [UUID: RevisionEntry] = [:]
    private var revisionOrder: [(itemID: UUID, stamp: UInt64)] = []
    private var revisionOrderCursor = 0
    private var deletionsByItemID: [UUID: DeletionEntry] = [:]
    private var deletionOrder: [(itemID: UUID, stamp: UInt64)] = []
    private var deletionOrderCursor = 0
    private(set) var clearGeneration: UInt64 = 0
    private(set) var clearSurvivingItemIDs: Set<UUID> = []
    private(set) var clearSurvivorSetIsAuthoritative = true
    private(set) var deletionEvictionGeneration: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var snapshot: HistoryContentRevisionReconciliationSnapshot {
        HistoryContentRevisionReconciliationSnapshot(
            knownRevisionsByItemID: revisionsByItemID.mapValues(\.revision),
            deletedItemIDs: Set(deletionsByItemID.keys),
            clearGeneration: clearGeneration,
            clearSurvivingItemIDs: clearSurvivingItemIDs,
            clearSurvivorSetIsAuthoritative: clearSurvivorSetIsAuthoritative,
            deletionEvictionGeneration: deletionEvictionGeneration
        )
    }

    var testingQueueCounts: (revision: Int, deletion: Int) {
        (revisionOrder.count, deletionOrder.count)
    }

    func revision(for itemID: UUID) -> ClipboardItemContentRevision? {
        revisionsByItemID[itemID]?.revision
    }

    func isDeleted(itemID: UUID) -> Bool {
        deletionsByItemID[itemID] != nil
    }

    func acceptsProjection(itemID: UUID) -> Bool {
        !isDeleted(itemID: itemID)
    }

    @discardableResult
    mutating func merge(
        items: [ClipboardItemDTO],
        allowRevivingDeletedItems: Bool
    ) -> Bool {
        var changed = false
        for item in items {
            let revision = ClipboardItemContentRevision.resolve(item: item)
            if deletionsByItemID[item.id] != nil {
                guard allowRevivingDeletedItems else { continue }
                deletionsByItemID.removeValue(forKey: item.id)
                changed = true
            }
            if let existing = revisionsByItemID[item.id],
               existing.revision == revision,
               existing.isPinned == item.isPinned {
                continue
            }

            let stamp = makeStamp()
            revisionsByItemID[item.id] = RevisionEntry(
                revision: revision,
                isPinned: item.isPinned,
                stamp: stamp
            )
            revisionOrder.append((item.id, stamp))
            changed = true
        }
        evictRevisionsIfNeeded()
        compactQueuesIfNeeded()
        return changed
    }

    @discardableResult
    mutating func invalidate(itemID: UUID) -> Bool {
        var changed = revisionsByItemID.removeValue(forKey: itemID) != nil
        if deletionsByItemID[itemID] == nil {
            let stamp = makeStamp()
            deletionsByItemID[itemID] = DeletionEntry(stamp: stamp)
            deletionOrder.append((itemID, stamp))
            changed = true
        }
        evictDeletionsIfNeeded()
        compactQueuesIfNeeded()
        return changed
    }
    @discardableResult
    mutating func invalidate(itemIDs: Set<UUID>) -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        var newlyDeletedCount = 0
        for itemID in itemIDs {
            revisionsByItemID.removeValue(forKey: itemID)
            if deletionsByItemID[itemID] == nil {
                let stamp = makeStamp()
                deletionsByItemID[itemID] = DeletionEntry(stamp: stamp)
                deletionOrder.append((itemID, stamp))
                newlyDeletedCount += 1
            }
        }
        evictDeletionsIfNeeded()
        compactQueuesIfNeeded()
        return newlyDeletedCount
    }

    @discardableResult
    mutating func setPinned(itemID: UUID, isPinned: Bool) -> Bool {
        guard let existing = revisionsByItemID[itemID],
              existing.isPinned != isPinned else { return false }
        let stamp = makeStamp()
        revisionsByItemID[itemID] = RevisionEntry(
            revision: existing.revision,
            isPinned: isPinned,
            stamp: stamp
        )
        revisionOrder.append((itemID, stamp))
        compactQueuesIfNeeded()
        return true
    }

    mutating func clear(
        survivingPinnedItems: [ClipboardItemDTO],
        survivorSetIsAuthoritative: Bool = true
    ) {
        guard !survivingPinnedItems.isEmpty || !survivorSetIsAuthoritative else {
            clearSurvivingItemIDs = []
            clearSurvivorSetIsAuthoritative = true
            revisionsByItemID.removeAll(keepingCapacity: true)
            revisionOrder.removeAll(keepingCapacity: true)
            revisionOrderCursor = 0
            deletionsByItemID.removeAll(keepingCapacity: true)
            deletionOrder.removeAll(keepingCapacity: true)
            deletionOrderCursor = 0
            clearGeneration &+= 1
            return
        }

        var survivingPinnedItemIDs = Set(survivingPinnedItems.map(\.id))
        if !survivorSetIsAuthoritative {
            survivingPinnedItemIDs.formUnion(
                revisionsByItemID.compactMap { itemID, entry in
                    entry.isPinned ? itemID : nil
                }
            )
        }
        let removedItemIDs = revisionsByItemID.keys.filter {
            !survivingPinnedItemIDs.contains($0)
        }
        for itemID in removedItemIDs {
            _ = invalidate(itemID: itemID)
        }
        _ = merge(
            items: survivingPinnedItems,
            allowRevivingDeletedItems: true
        )
        // Keep the clear survivor proof separate from the bounded revision registry. A successful
        // fetch is authoritative even when not every pinned revision fits; a failed fetch records
        // only best-known survivors and tells retained sessions to preserve capacity-unknown rows.
        clearSurvivingItemIDs = survivingPinnedItemIDs
        clearSurvivorSetIsAuthoritative = survivorSetIsAuthoritative
        clearGeneration &+= 1
    }

    private mutating func makeStamp() -> UInt64 {
        nextStamp &+= 1
        return nextStamp
    }

    private mutating func evictRevisionsIfNeeded() {
        while revisionsByItemID.count > capacity, revisionOrderCursor < revisionOrder.count {
            let candidate = revisionOrder[revisionOrderCursor]
            revisionOrderCursor += 1
            guard revisionsByItemID[candidate.itemID]?.stamp == candidate.stamp else { continue }
            revisionsByItemID.removeValue(forKey: candidate.itemID)
        }
    }

    private mutating func evictDeletionsIfNeeded() {
        while deletionsByItemID.count > capacity, deletionOrderCursor < deletionOrder.count {
            let candidate = deletionOrder[deletionOrderCursor]
            deletionOrderCursor += 1
            guard deletionsByItemID[candidate.itemID]?.stamp == candidate.stamp else { continue }
            deletionsByItemID.removeValue(forKey: candidate.itemID)
            deletionEvictionGeneration &+= 1
        }
    }

    private mutating func compactQueuesIfNeeded() {
        if revisionOrder.count > capacity * 4 {
            revisionOrder = revisionsByItemID.map { itemID, entry in
                (itemID: itemID, stamp: entry.stamp)
            }.sorted { $0.stamp < $1.stamp }
            revisionOrderCursor = 0
        } else if revisionOrderCursor > capacity,
                  revisionOrderCursor * 2 > revisionOrder.count {
            revisionOrder.removeFirst(revisionOrderCursor)
            revisionOrderCursor = 0
        }
        if deletionOrder.count > capacity * 4 {
            deletionOrder = deletionsByItemID.map { itemID, entry in
                (itemID: itemID, stamp: entry.stamp)
            }.sorted { $0.stamp < $1.stamp }
            deletionOrderCursor = 0
        } else if deletionOrderCursor > capacity,
                  deletionOrderCursor * 2 > deletionOrder.count {
            deletionOrder.removeFirst(deletionOrderCursor)
            deletionOrderCursor = 0
        }
    }
}

@Observable
@MainActor
final class HistoryViewModel {
    private struct PinnedSurvivorResolution {
        let items: [ClipboardItemDTO]
        let isAuthoritative: Bool
    }
    struct Timing: Sendable {
        var searchDebounceNs: UInt64
        var refineShortQueryDelayNs: UInt64
        var refineLongQueryDelayNs: UInt64
        var recentAppsRefreshDelayNs: UInt64
        var staleLoadRetryDelayNs: UInt64

        static let production = Timing(
            // v0.29+: 更快的首屏反馈（10ms 级）
            searchDebounceNs: 0,
            // v0.57+: 长词全量校准足够快，refine 立即执行；短词保留极短 delay 避免抖动
            refineShortQueryDelayNs: 10_000_000,
            refineLongQueryDelayNs: 0,
            recentAppsRefreshDelayNs: 500_000_000,
            staleLoadRetryDelayNs: 100_000_000
        )

        static let tests = Timing(
            searchDebounceNs: 20_000_000,
            refineShortQueryDelayNs: 40_000_000,
            refineLongQueryDelayNs: 40_000_000,
            recentAppsRefreshDelayNs: 20_000_000,
            staleLoadRetryDelayNs: 20_000_000
        )
    }

    // MARK: - Properties

    @ObservationIgnored private var service: ClipboardServiceProtocol
    @ObservationIgnored private let settingsViewModel: SettingsViewModel
    @ObservationIgnored private var timing: Timing = .production

    @ObservationIgnored var closePanelHandler: (() -> Void)?
    @ObservationIgnored var pasteAfterCopyHandler: (() -> Void)?

    static let initialPageSize = 50
    static let loadMorePageSize = 100
    static let knownContentRevisionCapacity = 4096

    private var listState = HistoryListState()
    @ObservationIgnored private var contentRevisionRegistry =
        BoundedHistoryContentRevisionRegistry(capacity: knownContentRevisionCapacity)

    private(set) var contentRevisionReconciliationToken: UInt64 = 0

    var contentRevisionReconciliationSnapshot: HistoryContentRevisionReconciliationSnapshot {
        contentRevisionRegistry.snapshot
    }

    func isContentRevisionCurrent(
        itemID: UUID,
        revision: ClipboardItemContentRevision
    ) -> Bool {
        guard !contentRevisionRegistry.isDeleted(itemID: itemID) else { return false }
        if let knownRevision = contentRevisionRegistry.revision(for: itemID) {
            return knownRevision == revision
        }
        guard let projectedItem = listState.item(withID: itemID) else { return false }
        return ClipboardItemContentRevision.resolve(item: projectedItem) == revision
    }

    var pinnedItems: [ClipboardItemDTO] {
        listState.pinnedItems
    }

    var unpinnedItems: [ClipboardItemDTO] {
        listState.unpinnedItems
    }

    var items: [ClipboardItemDTO] {
        get { listState.items }
        set {
            let currentItems = excludingKnownDeletedItems(newValue)
            listState.replaceItems(currentItems)
            mergeKnownContentRevisions(currentItems)
            if isUnfilteredList {
                searchMatchContexts.removeAll(keepingCapacity: true)
            }
        }
    }

    private(set) var searchMatchContexts: [UUID: SearchMatchContext] = [:]

    func searchMatchContext(for itemID: UUID) -> SearchMatchContext? {
        searchMatchContexts[itemID]
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
    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            rowSelection.update(selectedID: selectedID, follow: lastSelectionSource == .keyboard)
        }
    }

    /// Visible rows subscribe to their own selection here; see `HistoryRowSelectionFanout`.
    /// `lastSelectionSource` must be set before `selectedID` so the fan-out knows whether to follow.
    let rowSelection = HistoryRowSelectionFanout()

    var isPinnedCollapsed: Bool = false

    var appFilter: String?
    var typeFilter: ClipboardItemType?
    var typeFilters: Set<ClipboardItemType>?
    var recentApps: [String] = []

    private var hasSemanticSearchQuery: Bool {
        SearchRequest(query: searchQuery, mode: searchMode).hasSemanticQuery
    }

    var hasActiveFilters: Bool {
        hasSemanticSearchQuery || appFilter != nil || typeFilter != nil || typeFilters != nil
    }

    private var isUnfilteredList: Bool {
        !hasActiveFilters
    }

    var lastSelectionSource: SelectionSource = .programmatic

    var isScrolling: Bool = false

    private var searchVersion: Int = 0

    var canLoadMore: Bool {
        listState.canLoadMore
    }
    var loadedCount: Int {
        listState.loadedCount
    }
    var itemsRevision: UInt64 {
        listState.itemsRevision
    }
    var totalCount: Int {
        listState.totalCount
    }
    var searchCoverage: SearchCoverage = .complete

    var performanceSummary: PerformanceSummary?

    var searchCoverageHint: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSemanticSearchQuery else { return nil }

        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            return nil
        case .stagedRefine:
            return "首屏为预筛结果，正在全量校准…（排序/漏项可能会更新）"
        case .incomplete:
            return "结果未完成（排序/漏项可能不完整）"
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
        guard hasSemanticSearchQuery else { return searchModeDisplayName(searchMode) }

        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            return searchModeDisplayName(searchMode)
        case .stagedRefine:
            return "Calibrating"
        case .incomplete:
            return "Partial"
        case .recentOnly(let limit):
            return "Recent \(limit)"
        }
    }

    var searchStatusSummary: String {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = searchModeDisplayName(searchMode)
        guard hasSemanticSearchQuery else { return "Mode: \(mode)" }

        let coverage: String
        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            coverage = "Complete"
        case .stagedRefine:
            coverage = "Staged"
        case .incomplete:
            coverage = "Partial"
        case .recentOnly(let limit):
            coverage = "Recent \(limit)"
        }

        return "Mode: \(mode) · Coverage: \(coverage) · Sort: \(searchSortDisplayName(for: trimmed))"
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var staleLoadRetryTask: Task<Void, Never>?
    @ObservationIgnored private var storageDetailsTask: Task<Void, Never>?
    @ObservationIgnored private var recentAppsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var persistedDefaultSearchMode: SearchMode = SettingsDTO.default.defaultSearchMode
    @ObservationIgnored private var followsPersistedDefaultSearchMode: Bool = true
    @ObservationIgnored private var isApplyingPersistedDefaultSearchMode: Bool = false
    @ObservationIgnored private var didApplyScrollProfileSearch = false

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
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)
        self.service = service
    }

    func applyScrollProfileSearchIfNeeded() async {
        let environment = ProcessInfo.processInfo.environment
        guard !didApplyScrollProfileSearch,
              environment["SCOPY_SCROLL_PROFILE"] == "1",
              let query = environment["SCOPY_PROFILE_SEARCH_QUERY"],
              !query.isEmpty else { return }

        didApplyScrollProfileSearch = true
        if let rawMode = environment["SCOPY_PROFILE_SEARCH_MODE"],
           let mode = SearchMode(rawValue: rawMode) {
            searchMode = mode
        }
        searchQuery = query
        search()
        await searchTask?.value
    }

    func stop() {
        cancelTask(&searchTask)
        cancelTask(&loadMoreTask)
        cancelTask(&refineTask)
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)
        cancelTask(&recentAppsRefreshTask)
    }

    // MARK: - Event Handling

    func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem(let item):
            mergeKnownContentRevisions([item], allowRevivingDeletedItems: true)
            if let bundleID = item.appBundleID, !recentApps.contains(bundleID) {
                scheduleRecentAppsRefresh()
            }

            if hasSemanticSearchQuery {
                refreshSemanticSearchProjection()
                return
            }

            let didMatchCurrentFilters = matchesCurrentFilters(item)

            if didMatchCurrentFilters {
                _ = insertOrMoveItemToFront(item)
                prewarmDisplayText(for: [item])
            } else {
                _ = removeItem(withID: item.id)
            }

            if didMatchCurrentFilters, totalCount >= 0 {
                listState.incrementTotalCount()
            } else if isUnfilteredList, totalCount >= 0 {
                listState.incrementTotalCount()
            }
        case .thumbnailUpdated(
            let itemID,
            let expectedType,
            let expectedContentHash,
            let thumbnailPath
        ):
            ThumbnailCache.shared.remove(path: thumbnailPath)
            guard let index = indexOfItem(withID: itemID) else { return }
            let existing = items[index]
            guard existing.type == expectedType,
                  existing.contentHash == expectedContentHash else { return }
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
            mergeKnownContentRevisions([item])
            guard !contentRevisionRegistry.isDeleted(itemID: item.id) else { return }

            // Usage and last-used updates (including copy) keep their current search position
            // and evidence. Content mutations arrive through itemContentUpdated and re-search.
            if hasSemanticSearchQuery {
                guard let index = indexOfItem(withID: item.id) else { return }
                setItemIfChanged(at: index, to: item)
                prewarmDisplayText(for: [item])
                return
            }

            let didMatchCurrentFilters = matchesCurrentFilters(item)
            if didMatchCurrentFilters {
                _ = insertOrMoveItemToFront(item)
                prewarmDisplayText(for: [item])
            } else {
                _ = removeItem(withID: item.id)
            }

            if totalCount >= 0 {
                listState.recomputeCanLoadMore()
            }
        case .itemContentUpdated(let item):
            mergeKnownContentRevisions([item])
            guard !contentRevisionRegistry.isDeleted(itemID: item.id) else { return }
            if hasSemanticSearchQuery {
                refreshSemanticSearchProjection()
                return
            }
            guard let index = indexOfItem(withID: item.id) else { return }
            let existing = items[index]
            if existing.thumbnailPath != item.thumbnailPath, let oldPath = existing.thumbnailPath {
                ThumbnailCache.shared.remove(path: oldPath)
            }
            setItemIfChanged(at: index, to: item)
            prewarmDisplayText(for: [item])
        case .itemDeleted(let id):
            invalidateKnownContentRevision(itemID: id)
            invalidateInFlightProjectionWorkForDeletion()
            let wasPresent = removeItem(withID: id)

            listState.decrementTotalCountIfNeeded(
                wasPresent: wasPresent,
                isUnfilteredList: isUnfilteredList
            )
            if hasActiveFilters {
                search()
            }
        case .itemsRemoved(let itemIDs):
            let deletedIDs = Set(itemIDs)
            guard !deletedIDs.isEmpty else { return }
            let newlyDeletedCount = invalidateKnownContentRevisions(itemIDs: deletedIDs)
            invalidateInFlightProjectionWorkForDeletion()
            _ = listState.removeItems(withIDs: deletedIDs)
            for id in deletedIDs {
                searchMatchContexts.removeValue(forKey: id)
            }

            if isUnfilteredList {
                // Refresh only the authoritative count. Re-fetching the first page here would
                // collapse a user's already-loaded pagination depth back to the initial 50 rows.
                let projectionVersion = searchVersion
                do {
                    let stats = try await service.getStorageStats()
                    guard projectionVersion == searchVersion, isUnfilteredList else { return }
                    listState.updateTotalCount(stats.itemCount)
                    settingsViewModel.storageStats = stats
                } catch {
                    guard projectionVersion == searchVersion, isUnfilteredList else { return }
                    // Exact committed IDs are still the best available authority on a transient
                    // stats read failure; duplicate bulk events do not decrement twice.
                    listState.decrementTotalCount(by: newlyDeletedCount)
                    ScopyLog.app.error(
                        "Failed to refresh history count after cleanup: \(error.localizedDescription, privacy: .private)"
                    )
                }
            } else {
                search()
            }
        case .itemPinned(let id):
            setKnownContentPinned(itemID: id, isPinned: true)
            if let index = indexOfItem(withID: id) {
                let updated = items[index].withPinned(true)
                setItemIfChanged(at: index, to: updated)
                mergeKnownContentRevisions([updated])
            }
        case .itemUnpinned(let id):
            setKnownContentPinned(itemID: id, isPinned: false)
            if let index = indexOfItem(withID: id) {
                let updated = items[index].withPinned(false)
                setItemIfChanged(at: index, to: updated)
                mergeKnownContentRevisions([updated])
            }
        case .itemsCleared(let keepPinned):
            let pinnedSurvivors = await resolvePinnedSurvivors(
                keepPinned: keepPinned
            )
            prepareForItemsCleared(pinnedSurvivors: pinnedSurvivors)
            await refreshAfterItemsCleared()
        case .settingsChanged:
            break
        }
    }

    // MARK: - Settings Synchronization

    func applySettings(_ settings: SettingsDTO) {
        persistedDefaultSearchMode = settings.defaultSearchMode
        guard followsPersistedDefaultSearchMode else { return }
        let previousMode = searchMode
        isApplyingPersistedDefaultSearchMode = true
        searchMode = settings.defaultSearchMode
        followsPersistedDefaultSearchMode = true
        if previousMode != searchMode, hasSemanticSearchQuery {
            search()
        }
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
        if hasSemanticSearchQuery {
            return false
        }
        return true
    }

    // MARK: - Loading

    func load() async {
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)
        let currentVersion = searchVersion
        guard shouldApplyLoadResult(version: currentVersion) else { return }

        isLoading = true
        defer {
            if currentVersion == searchVersion {
                isLoading = false
            }
        }

        do {
            let startTime = CFAbsoluteTimeGetCurrent()

            var fetchedItems: [ClipboardItemDTO] = []
            var hasStableSnapshot = false
            for _ in 0..<2 {
                let revisionBeforeFetch = itemsRevision
                let pinnedItems = try await service.fetchPinned()
                let recentItems = try await service.fetchRecentUnpinned(
                    limit: Self.initialPageSize,
                    offset: 0
                )
                guard shouldApplyLoadResult(version: currentVersion) else { return }
                guard itemsRevision == revisionBeforeFetch else { continue }
                fetchedItems = excludingKnownDeletedItems(pinnedItems + recentItems)
                hasStableSnapshot = true
                break
            }
            guard shouldApplyLoadResult(version: currentVersion) else { return }
            guard hasStableSnapshot else {
                scheduleLoadAfterStaleSnapshot(version: currentVersion)
                return
            }

            listState.replaceItems(fetchedItems)
            searchMatchContexts.removeAll(keepingCapacity: true)
            mergeKnownContentRevisions(fetchedItems)
            prewarmDisplayText(for: fetchedItems)
            searchCoverage = .complete
            lastLoadedAt = Date()

            // Load latency should reflect "first screen ready" rather than unrelated background work.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            await PerformanceMetrics.shared.recordLoadLatency(elapsedMs)
            guard shouldApplyLoadResult(version: currentVersion) else { return }

            performanceSummary = await PerformanceMetrics.shared.getSummary()
            guard shouldApplyLoadResult(version: currentVersion) else { return }

            let stats = try await service.getStorageStats()
            guard shouldApplyLoadResult(version: currentVersion) else { return }

            listState.updateTotalCount(stats.itemCount)

            settingsViewModel.storageStats = stats
            scheduleStorageDetailsRefresh(version: currentVersion)
        } catch {
            ScopyLog.app.error("Failed to load items: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func shouldApplyLoadResult(version: Int) -> Bool {
        !Task.isCancelled && version == searchVersion && isUnfilteredList
    }

    private func scheduleLoadAfterStaleSnapshot(version: Int) {
        guard staleLoadRetryTask == nil else { return }
        staleLoadRetryTask = Task {
            do {
                try await Task.sleep(nanoseconds: timing.staleLoadRetryDelayNs)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard version == searchVersion, isUnfilteredList else {
                staleLoadRetryTask = nil
                return
            }

            // Clear ownership before reloading so another double collision can schedule
            // exactly one successor instead of being blocked by this completed task.
            staleLoadRetryTask = nil
            await load()
        }
    }

    private func scheduleStorageDetailsRefresh(version: Int) {
        cancelTask(&storageDetailsTask)
        storageDetailsTask = Task {
            do {
                let details = try await service.getDetailedStorageStats()
                guard shouldApplyLoadResult(version: version) else { return }

                settingsViewModel.diskSizeBytes = details.totalSizeBytes
                settingsViewModel.syncExternalImageSizeBytesFromDiskIfNeeded()
            } catch {
                guard shouldApplyLoadResult(version: version) else { return }
                ScopyLog.app.error(
                    "Failed to get disk size: \(error.localizedDescription, privacy: .private)"
                )
            }
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
        ScrollPerformanceProfile.shared.incrementCounter(name: "list.load_more_attempt")
        if let inFlightTask = loadMoreTask {
            await inFlightTask.value
            return
        }

        let currentVersion = searchVersion

        let task = Task {
            defer {
                if currentVersion == searchVersion {
                    loadMoreTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            guard canLoadMore, !isLoading else { return }

            isLoading = true
            defer {
                if currentVersion == searchVersion {
                    isLoading = false
                }
            }

            do {
                if !isUnfilteredList {
                    // When current result is prefilter (total = -1), force full fuzzy before paging.
                    if (searchCoverage == .stagedRefine || searchCoverage == .incomplete),
                       (searchMode == .fuzzy || searchMode == .fuzzyPlus) {
                        let expectedLimit = loadedCount + Self.loadMorePageSize
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
                        ScrollPerformanceProfile.shared.incrementCounter(
                            name: "list.pagination_request"
                        )
                        let result = try await service.search(query: request)
                        guard !Task.isCancelled, currentVersion == searchVersion else { return }
                        replaceSearchPage(with: result)
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
                        limit: Self.loadMorePageSize,
                        offset: loadedCount
                    )
                    ScrollPerformanceProfile.shared.incrementCounter(
                        name: "list.pagination_request"
                    )
                    let result = try await service.search(query: request)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    appendSearchPage(with: result)
                    searchCoverage = result.coverage
                } else {
                    ScrollPerformanceProfile.shared.incrementCounter(
                        name: "list.pagination_request"
                    )
                    let moreItems = try await service.fetchRecentUnpinned(
                        limit: Self.loadMorePageSize,
                        offset: unpinnedItems.count
                    )
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    let currentItems = excludingKnownDeletedItems(moreItems)
                    listState.appendRecentPage(items: currentItems)
                    mergeKnownContentRevisions(currentItems)
                    prewarmDisplayText(for: currentItems)
                    searchCoverage = .complete
                }
            } catch {
                if !Task.isCancelled {
                    ScopyLog.app.error("Failed to load more: \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        loadMoreTask = task
        await task.value
    }

    // MARK: - Search

    func search() {
        startSearch(preservingCurrentProjection: false)
    }

    private func refreshSemanticSearchProjection() {
        startSearch(preservingCurrentProjection: true)
    }

    private func startSearch(preservingCurrentProjection: Bool) {
        cancelTask(&searchTask)
        cancelTask(&refineTask)
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)

        searchVersion += 1
        let currentVersion = searchVersion

        cancelTask(&loadMoreTask)
        if !preservingCurrentProjection {
            clearSearchProjection()
        }

        if isUnfilteredList {
            searchTask = Task {
                guard !Task.isCancelled else { return }
                guard currentVersion == searchVersion else { return }
                await load()
            }
            return
        }

        // User-initiated query changes clear stale rows above. Event-driven refreshes retain the
        // current projection until the versioned replacement arrives. Own the loading state across
        // the debounce in both cases.
        isLoading = true
        searchTask = Task {
            defer {
                if currentVersion == searchVersion {
                    isLoading = false
                }
            }
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let debounceNs = effectiveSearchDebounceNs(for: query)
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return }
            guard currentVersion == searchVersion else { return }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()

                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    sortMode: ftsSortMode,
                    appFilter: appFilter,
                    typeFilter: typeFilter,
                    typeFilters: typeFilters,
                    limit: Self.initialPageSize,
                    offset: 0
                )
                let result = try await service.search(query: request)
                guard !Task.isCancelled, currentVersion == searchVersion else { return }
                replaceSearchPage(with: result)
                searchCoverage = result.coverage

                if (searchMode == .fuzzy || searchMode == .fuzzyPlus),
                   result.coverage.isStagedRefine,
                   loadedCount <= Self.initialPageSize {
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
                            limit: Self.initialPageSize,
                            offset: 0
                        )

                        do {
                            let refined = try await service.search(query: refineRequest)
                            guard !Task.isCancelled, refineVersion == searchVersion else { return }

                            guard loadedCount <= Self.initialPageSize else { return }
                            replaceSearchPage(with: refined)
                            searchCoverage = refined.coverage
                        } catch {
                            guard !Task.isCancelled, refineVersion == searchVersion else { return }
                            guard searchCoverage.isStagedRefine else { return }
                            searchCoverage = .incomplete
                            ScopyLog.app.warning("Refine search failed: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await PerformanceMetrics.shared.recordSearchLatency(elapsedMs)
                performanceSummary = await PerformanceMetrics.shared.getSummary()
            } catch {
                guard !Task.isCancelled, currentVersion == searchVersion else { return }
                if preservingCurrentProjection {
                    searchCoverage = .incomplete
                } else {
                    clearSearchProjection()
                    searchCoverage = .complete
                }
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
            pasteAfterCopyHandler?()
        } catch {
            ScopyLog.app.error("Codex-optimized copy failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func sendViaAirDrop(_ item: ClipboardItemDTO) async {
        let urls = await resolvedFileURLs(for: item)
        guard !urls.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            ScopyLog.app.error("AirDrop sharing service is unavailable")
            return
        }
        service.perform(withItems: urls)
    }

    func openContainingFolder(_ item: ClipboardItemDTO) async {
        let urls = realFileURLs(for: item)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func clearSearchForPanelReopen() {
        selectedID = nil
        lastSelectionSource = .programmatic
        guard !searchQuery.isEmpty else { return }
        searchQuery = ""
        search()
    }

    func togglePin(_ item: ClipboardItemDTO) async {
        do {
            if item.isPinned {
                try await service.unpin(itemID: item.id)
            } else {
                try await service.pin(itemID: item.id)
            }
            mergeKnownContentRevisions([item.withPinned(!item.isPinned)])
        } catch {
            ScopyLog.app.error("Pin toggle failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    @discardableResult
    func delete(_ item: ClipboardItemDTO) async -> Bool {
        do {
            try await service.delete(itemID: item.id)
            invalidateKnownContentRevision(itemID: item.id)
            _ = removeItem(withID: item.id)
            return true
        } catch {
            ScopyLog.app.error("Delete failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func updateNote(_ item: ClipboardItemDTO, note: String?) async -> Bool {
        do {
            try await service.updateNote(itemID: item.id, note: note)
            return true
        } catch {
            ScopyLog.app.error("Update note failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func clearAll() async {
        do {
            try await service.clearAll()
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
        let nextID: UUID?
        if let currentID = selectedID,
           let currentIndex = indexOfItem(withID: currentID),
           currentIndex < items.count - 1 {
            nextID = items[currentIndex + 1].id
        } else {
            nextID = items.first?.id
        }
        selectedID = nextID
    }

    func highlightPrevious() {
        guard !items.isEmpty else { return }
        lastSelectionSource = .keyboard
        let nextID: UUID?
        if let currentID = selectedID,
           let currentIndex = indexOfItem(withID: currentID),
           currentIndex > 0 {
            nextID = items[currentIndex - 1].id
        } else {
            nextID = items.last?.id
        }
        selectedID = nextID
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

        guard await delete(items[index]) else { return }

        lastSelectionSource = .programmatic
        selectedID = nextID
    }

    func selectCurrent() async {
        if let selectedID,
           let index = indexOfItem(withID: selectedID) {
            await select(items[index])
        }
    }

    // MARK: - Private

    private func prewarmDisplayText(for items: [ClipboardItemDTO]) {
        guard !items.isEmpty else { return }
        ClipboardItemDisplayText.shared.prewarm(items: items)
        HistoryItemPresentationCache.shared.prewarm(items: items)
    }

    private func excludingKnownDeletedItems(
        _ items: [ClipboardItemDTO]
    ) -> [ClipboardItemDTO] {
        items.filter { contentRevisionRegistry.acceptsProjection(itemID: $0.id) }
    }

    private func mergeKnownContentRevisions(
        _ items: [ClipboardItemDTO],
        allowRevivingDeletedItems: Bool = false
    ) {
        guard !items.isEmpty,
              contentRevisionRegistry.merge(
                  items: items,
                  allowRevivingDeletedItems: allowRevivingDeletedItems
              ) else { return }
        contentRevisionReconciliationToken &+= 1
    }

    private func invalidateKnownContentRevision(itemID: UUID) {
        guard contentRevisionRegistry.invalidate(itemID: itemID) else { return }
        contentRevisionReconciliationToken &+= 1
    }

    @discardableResult
    private func invalidateKnownContentRevisions(itemIDs: Set<UUID>) -> Int {
        let newlyDeletedCount = contentRevisionRegistry.invalidate(itemIDs: itemIDs)
        guard newlyDeletedCount > 0 else { return 0 }
        contentRevisionReconciliationToken &+= 1
        return newlyDeletedCount
    }

    private func setKnownContentPinned(itemID: UUID, isPinned: Bool) {
        guard contentRevisionRegistry.setPinned(
            itemID: itemID,
            isPinned: isPinned
        ) else { return }
        contentRevisionReconciliationToken &+= 1
    }

    private func clearKnownContentRevisions(
        pinnedSurvivors: PinnedSurvivorResolution
    ) {
        contentRevisionRegistry.clear(
            survivingPinnedItems: pinnedSurvivors.items,
            survivorSetIsAuthoritative: pinnedSurvivors.isAuthoritative
        )
        contentRevisionReconciliationToken &+= 1
    }

    private func invalidateInFlightProjectionWorkForDeletion() {
        cancelTask(&searchTask)
        cancelTask(&loadMoreTask)
        cancelTask(&refineTask)
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)
        searchVersion &+= 1
        isLoading = false
    }

    private func resolvePinnedSurvivors(
        keepPinned: Bool
    ) async -> PinnedSurvivorResolution {
        guard keepPinned else {
            return PinnedSurvivorResolution(items: [], isAuthoritative: true)
        }
        do {
            return PinnedSurvivorResolution(
                items: try await service.fetchPinned(),
                isAuthoritative: true
            )
        } catch {
            ScopyLog.app.error(
                "Failed to verify pinned items after clear: \(error.localizedDescription, privacy: .private)"
            )
            // A transient read failure is not proof that every pinned row disappeared. Preserve
            // the loaded projection plus registry-known pinned IDs; known unpinned rows still get
            // tombstoned by the non-authoritative clear boundary.
            return PinnedSurvivorResolution(
                items: listState.pinnedItems,
                isAuthoritative: false
            )
        }
    }

    private func prepareForItemsCleared(
        pinnedSurvivors: PinnedSurvivorResolution
    ) {
        cancelTask(&searchTask)
        cancelTask(&loadMoreTask)
        cancelTask(&refineTask)
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)
        searchVersion &+= 1
        isLoading = false
        selectedID = nil
        lastSelectionSource = .programmatic
        let preservedItems = isUnfilteredList ? pinnedSurvivors.items : []
        listState.replacePage(
            items: preservedItems,
            total: preservedItems.count,
            hasMore: false
        )
        searchMatchContexts.removeAll(keepingCapacity: true)
        searchCoverage = .complete
        lastLoadedAt = .distantPast
        clearKnownContentRevisions(pinnedSurvivors: pinnedSurvivors)
    }

    private func refreshAfterItemsCleared() async {
        if isUnfilteredList {
            await load()
            return
        }

        search()
        await searchTask?.value
    }

    private func resolvedFileURLs(for item: ClipboardItemDTO) async -> [URL] {
        if let urls = try? await service.fileURLs(itemID: item.id), !urls.isEmpty {
            return urls
        }
        return FilePreviewSupport.fileURLs(from: item.plainText, requireExists: true)
    }

    private func realFileURLs(for item: ClipboardItemDTO) -> [URL] {
        switch item.type {
        case .file:
            return FilePreviewSupport.fileURLs(from: item.plainText, requireExists: true)
        case .image:
            if let storageRef = item.storageRef, !storageRef.isEmpty {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: storageRef, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return [URL(fileURLWithPath: storageRef)]
                }
            }
            return FilePreviewSupport.fileURLs(from: item.plainText, requireExists: true)
        case .text, .rtf, .html, .other:
            return []
        }
    }

    private func indexOfItem(withID id: UUID) -> Int? {
        listState.indexOfItem(withID: id)
    }

    private func acceptedSearchHits(_ hits: [SearchResultHit]) -> [SearchResultHit] {
        hits.filter { contentRevisionRegistry.acceptsProjection(itemID: $0.item.id) }
    }

    private func replaceSearchPage(with result: SearchResultPage) {
        let hits = acceptedSearchHits(result.hits)
        let resultItems = hits.map(\.item)
        listState.replacePage(
            items: resultItems,
            total: result.total,
            hasMore: result.hasMore
        )
        searchMatchContexts = Dictionary(
            uniqueKeysWithValues: hits.compactMap { hit in
                hit.matchContext.map { (hit.item.id, $0) }
            }
        )
        mergeKnownContentRevisions(resultItems)
        prewarmDisplayText(for: resultItems)
        reconcileSelectionAfterProjectionReplacement()
    }

    private func appendSearchPage(with result: SearchResultPage) {
        let hits = acceptedSearchHits(result.hits)
        let resultItems = hits.map(\.item)
        listState.appendPage(
            items: resultItems,
            total: result.total,
            hasMore: result.hasMore
        )
        var mergedContexts = searchMatchContexts
        for hit in hits {
            if let matchContext = hit.matchContext {
                mergedContexts[hit.item.id] = matchContext
            }
        }
        searchMatchContexts = mergedContexts
        mergeKnownContentRevisions(resultItems)
        prewarmDisplayText(for: resultItems)
    }

    private func clearSearchProjection() {
        listState.replacePage(items: [], total: 0, hasMore: false)
        searchMatchContexts.removeAll(keepingCapacity: true)
        selectedID = nil
    }

    private func reconcileSelectionAfterProjectionReplacement() {
        guard let selectedID, indexOfItem(withID: selectedID) == nil else { return }
        self.selectedID = nil
        lastSelectionSource = .programmatic
    }

    @discardableResult
    private func setItemIfChanged(at index: Int, to value: ClipboardItemDTO) -> Bool {
        listState.setItemIfChanged(at: index, to: value)
    }

    @discardableResult
    private func removeItem(withID id: UUID) -> Bool {
        searchMatchContexts.removeValue(forKey: id)
        if selectedID == id {
            selectedID = nil
            lastSelectionSource = .programmatic
        }
        return listState.removeItem(withID: id)
    }

    @discardableResult
    private func insertOrMoveItemToFront(_ item: ClipboardItemDTO) -> Bool {
        listState.insertOrMoveItemToFront(item)
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
