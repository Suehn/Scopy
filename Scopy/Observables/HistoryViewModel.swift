import AppKit
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
        /// How long a deleted row stays undoable before the backend delete is sent.
        var undoDeletionWindowNs: UInt64

        static let production = Timing(
            searchDebounceNs: 0,
            // Long queries refine at once; short ones keep a tiny delay so the page does not flicker.
            refineShortQueryDelayNs: 10_000_000,
            refineLongQueryDelayNs: 0,
            recentAppsRefreshDelayNs: 500_000_000,
            undoDeletionWindowNs: 5_000_000_000
        )

        static let tests = Timing(
            searchDebounceNs: 20_000_000,
            refineShortQueryDelayNs: 40_000_000,
            refineLongQueryDelayNs: 40_000_000,
            recentAppsRefreshDelayNs: 20_000_000,
            undoDeletionWindowNs: 50_000_000
        )
    }

    private struct PendingDeletion {
        var item: ClipboardItemDTO
        var mutationSeq: Int64?
        let useCountAtDeletion: Int
        let token: UUID
        /// Which projection the row left and its neighbours there, so undo can put it straight
        /// back even after newer rows were inserted in front.
        let projection: UUID
        let index: Int
        let predecessorID: UUID?
        let successorID: UUID?
        var evidence: SearchMatchContext?
        let commit: Task<Void, Never>
    }

    // MARK: - Properties

    @ObservationIgnored private let service: ClipboardServiceProtocol
    @ObservationIgnored private let settingsViewModel: SettingsViewModel
    @ObservationIgnored private var timing: Timing = .production

    @ObservationIgnored var closePanelHandler: (() -> Void)?
    /// Scrolls the list to its first row; set by the list while it is mounted.
    @ObservationIgnored var scrollListToTop: (() -> Void)?
    @ObservationIgnored var pasteAfterCopyHandler: (() -> Void)?

    /// Message for an action that failed where the user expected it to work. A failed copy leaves
    /// the panel open, so it needs somewhere to say why instead of only reaching the log.
    private(set) var actionErrorMessage: String?
    @ObservationIgnored private var actionErrorClearTask: Task<Void, Never>?
    static let actionErrorVisibleSeconds: Double = 4

    /// The row removed by the last delete while its backend delete is still deferred. The footer
    /// offers Undo and ⌘Z restores the row only while this is set.
    var undoableDeletionID: UUID? { pendingDeletion?.item.id }
    private var pendingDeletion: PendingDeletion?
    @ObservationIgnored private var suppressedItemIDs: Set<UUID> = []
    @ObservationIgnored private var inFlightDeletions: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var deletionFailureGeneration: UInt64 = 0
    /// Changes when the user requests another projection or clears it. History events supersede
    /// request work, but Undo still belongs to the same query and loaded rows.
    @ObservationIgnored private var projectionIdentity = UUID()
    @ObservationIgnored private var quickSlotHintsVisible = false

    /// Why the last search, history load or page fetch failed. The rows on screen are kept; the
    /// footer shows this with a retry until the next search or load starts.
    private(set) var fetchFailureMessage: String?
    private(set) var captureReadBlocked = false

    static let initialPageSize = 50
    static let loadMorePageSize = 300
    static let knownContentRevisionCapacity = 4096

    /// Not observed as a whole: an in-place change (pagination, total) would invalidate every
    /// reader. Readers observe the three cells below, which `mutateProjection` writes only when
    /// their value changes.
    @ObservationIgnored private var listState = HistoryListState()
    private(set) var projectionGeneration: UInt64 = 0
    private(set) var totalCount = 0
    private(set) var canLoadMore = false
    @ObservationIgnored private var contentRevisionRegistry =
        BoundedHistoryContentRevisionRegistry(capacity: knownContentRevisionCapacity)

    private(set) var contentRevisionReconciliationToken: UInt64 = 0

    var contentRevisionReconciliationSnapshot: HistoryContentRevisionReconciliationSnapshot {
        let snapshot = contentRevisionRegistry.snapshot
        return HistoryContentRevisionReconciliationSnapshot(
            knownRevisionsByItemID: snapshot.knownRevisionsByItemID,
            deletedItemIDs: snapshot.deletedItemIDs.union(suppressedItemIDs)
        )
    }

    func isContentRevisionCurrent(
        itemID: UUID,
        revision: ClipboardItemContentRevision
    ) -> Bool {
        guard !suppressedItemIDs.contains(itemID), !contentRevisionRegistry.isDeleted(itemID: itemID) else { return false }
        if let knownRevision = contentRevisionRegistry.revision(for: itemID) {
            return knownRevision == revision
        }
        guard let projectedItem = listState.item(withID: itemID) else { return false }
        return ClipboardItemContentRevision.resolve(item: projectedItem) == revision
    }

    var pinnedItems: [ClipboardItemDTO] {
        _ = projectionGeneration
        return listState.pinnedItems
    }

    var unpinnedItems: [ClipboardItemDTO] {
        _ = projectionGeneration
        return listState.unpinnedItems
    }

    var items: [ClipboardItemDTO] {
        _ = projectionGeneration
        return listState.items
    }

    #if DEBUG
    func replaceItemsForTesting(_ newItems: [ClipboardItemDTO]) {
        let currentItems = excludingKnownDeletedItems(newItems)
        if isUnfilteredList { searchMatchContexts.removeAll(keepingCapacity: true) }
        mutateProjection { $0.replaceItemsForTesting(currentItems) }
    }
    #endif

    var loadedCount: Int {
        _ = projectionGeneration
        return listState.loadedCount
    }

    /// Evidence reaches rows through `rowLiveState`; the List body never reads this map.
    private(set) var searchMatchContexts: [UUID: SearchMatchContext] = [:] {
        didSet { rowLiveState.replaceEvidence(searchMatchContexts) }
    }

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
    var isLoading: Bool { requests.isLoading }
    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            rowLiveState.update(selectedID: selectedID, follow: lastSelectionSource == .keyboard)
        }
    }

    /// Visible rows subscribe to their selection and evidence here; see `HistoryRowLiveStateFanout`.
    /// `lastSelectionSource` must be set before `selectedID` so the fan-out knows whether to follow.
    let rowLiveState = HistoryRowLiveStateFanout()

    var isPinnedCollapsed: Bool = false {
        didSet {
            if quickSlotHintsVisible { fanOutQuickSlots() }
            // A collapsed pinned row is off screen; ⏎ and ⌥⌫ must not act on it.
            guard isPinnedCollapsed, let selectedID,
                  pinnedItems.contains(where: { $0.id == selectedID }) else { return }
            lastSelectionSource = .programmatic
            self.selectedID = nil
        }
    }

    /// Rows in on-screen order: the pinned section (unless collapsed), then recent rows.
    /// Keyboard navigation, ⏎ and ⌥⌫ act only on these.
    var displayOrderItems: [ClipboardItemDTO] {
        isPinnedCollapsed ? unpinnedItems : pinnedItems + unpinnedItems
    }

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

    /// Where the pointer was when the keyboard last moved the selection. Rows scrolling under a
    /// resting pointer report hover; that must not take the selection back until the pointer moves.
    @ObservationIgnored private var keyboardSelectionPointerAnchor: CGPoint?
    static let hoverSelectionPointerSlop: CGFloat = 3

    /// Hover still updates the selection (also while the search field is focused), but only once
    /// the pointer has really moved since the last keyboard navigation.
    func acceptHoverSelection(_ id: UUID) {
        if let anchor = keyboardSelectionPointerAnchor {
            let pointer = NSEvent.mouseLocation
            guard hypot(pointer.x - anchor.x, pointer.y - anchor.y) > Self.hoverSelectionPointerSlop else { return }
            keyboardSelectionPointerAnchor = nil
        }
        // Source first: the selection fan-out reads it when `selectedID` changes.
        lastSelectionSource = .mouse
        selectedID = id
    }

    var isScrolling: Bool = false

    private let requests = HistoryRequestLifecycle()
    @ObservationIgnored private var latestHistoryMutationSeq: Int64 = 0
    @ObservationIgnored private var activeHistoryReads: [UUID: HistoryReadChanges] = [:]
    /// Reads the IDs from their actual resource owners; this is not another mutable ID registry.
    @ObservationIgnored var retainedContentItemIDs: (() -> Set<UUID>)?
    @ObservationIgnored private var storageStatsRefreshTask: Task<Void, Never>?


    var searchCoverage: SearchCoverage = .complete

    var searchCoverageHint: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSemanticSearchQuery else { return nil }

        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            return nil
        case .stagedRefine:
            return String(localized: "Showing prefiltered results while the full search finishes; order and missing items may still change.")
        case .incomplete:
            return String(localized: "Results are incomplete; order and coverage may be partial.")
        case .recentOnly(let limit):
            switch searchMode {
            case .exact:
                return String(localized: "Exact queries of 2 or fewer characters search only the most recent \(String(limit)) items. Type 3 or more characters, or switch to Fuzzy+ or Fuzzy.")
            case .regex:
                return String(localized: "Regex searches only the most recent \(String(limit)) items. For a full search, use Exact with 3 or more characters, or Fuzzy+.")
            case .fuzzy, .fuzzyPlus:
                return String(localized: "Searching only the most recent \(String(limit)) items.")
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
            return String(localized: "Calibrating")
        case .incomplete:
            return String(localized: "Partial")
        case .recentOnly(let limit):
            return String(localized: "Recent \(String(limit))")
        }
    }

    var searchStatusSummary: String {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = searchModeDisplayName(searchMode)
        guard hasSemanticSearchQuery else { return String(localized: "Mode: \(mode)") }

        let coverage: String
        switch effectiveSearchCoverage(for: trimmed) {
        case .complete:
            coverage = String(localized: "Complete")
        case .stagedRefine:
            coverage = String(localized: "Staged")
        case .incomplete:
            coverage = String(localized: "Partial")
        case .recentOnly(let limit):
            coverage = String(localized: "Recent \(String(limit))")
        }

        return String(localized: "Mode: \(mode) · Coverage: \(coverage) · Sort: \(searchSortDisplayName(for: trimmed))")
    }

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
        await requests.waitForPrimary()
    }

    func stop() {
        requests.cancel()
        captureReadBlocked = false
        cancelTask(&storageDetailsTask)
        cancelTask(&recentAppsRefreshTask)
        cancelTask(&storageStatsRefreshTask)
    }

    // MARK: - Event Handling

    func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .history(let commit):
            for read in activeHistoryReads.values { read.record(commit) }
            latestHistoryMutationSeq = max(latestHistoryMutationSeq, commit.mutationSeq)
            protectRetainedContent()
            reconcilePendingDeletion(with: commit)

            switch commit.change {
            case .itemsChanged(let items, let kind):
                applyCommittedItems(items, kind: kind, mutationSeq: commit.mutationSeq)
            case .itemsRemoved(let ids):
                applyCommittedRemovals(Set(ids), mutationSeq: commit.mutationSeq)
            case .itemsCleared(let ids):
                applyCommittedRemovals(Set(ids), mutationSeq: commit.mutationSeq)
            }
            if isUnfilteredList {
                mutateProjection { $0.updateTotalCount(commit.totalCount, mutationSeq: commit.mutationSeq) }
                scheduleStorageStatsRefresh()
            }

        case .historyResnapshotRequired:
            await resnapshotHistory()

        case .thumbnailUpdated(let itemID, let expectedType, let expectedContentHash, let thumbnailPath):
            let thumbnail = HistoryReadChanges.Thumbnail(
                itemID: itemID, expectedType: expectedType,
                expectedContentHash: expectedContentHash, path: thumbnailPath
            )
            for read in activeHistoryReads.values { read.recordThumbnail(thumbnail) }
            ThumbnailCache.shared.remove(path: thumbnailPath)
            applyThumbnail(thumbnailPath, toItemID: itemID,
                           expectedType: expectedType, expectedContentHash: expectedContentHash)
        case .captureReadBlocked(let blocked):
            captureReadBlocked = blocked
        case .settingsChanged:
            break
        }
    }

    private func applyCommittedItems(
        _ incoming: [ClipboardItemDTO],
        kind: HistoryItemChangeKind,
        mutationSeq: Int64
    ) {
        let changed = incoming.filter {
            mutationSeq > (listState.mutationSeq(for: $0.id) ?? -1) &&
                contentRevisionRegistry.acceptsHistoryChange(itemID: $0.id, mutationSeq: mutationSeq)
        }.map { listState.preservingThumbnail(in: $0) }
        guard !changed.isEmpty else { return }
        mergeKnownContentRevisions(changed, mutationSeq: mutationSeq)
        if kind == .inserted,
           changed.contains(where: { $0.appBundleID.map { !recentApps.contains($0) } ?? false }) {
            scheduleRecentAppsRefresh()
        }
        if kind == .content {
            for item in changed {
                if let previous = listState.item(withID: item.id),
                   previous.thumbnailPath != item.thumbnailPath, let oldPath = previous.thumbnailPath {
                    ThumbnailCache.shared.remove(path: oldPath)
                }
            }
        }
        if hasSemanticSearchQuery, kind == .inserted || kind == .content {
            refreshSearchAfterHistoryChange()
            return
        }

        for item in changed {
            guard !suppressedItemIDs.contains(item.id) else { continue }
            guard listState.acceptsHistoryChange(itemID: item.id, mutationSeq: mutationSeq) else { continue }
            if hasSemanticSearchQuery {
                guard let index = indexOfItem(withID: item.id) else { continue }
                setItemIfChanged(at: index, to: item, mutationSeq: mutationSeq)
            } else if matchesCurrentFilters(item) {
                let wasLoaded = indexOfItem(withID: item.id) != nil
                if (kind == .content || kind == .metadata), !wasLoaded { continue }
                if kind == .pin, !wasLoaded, !item.isPinned { continue }
                _ = upsertRecentItem(item, mutationSeq: mutationSeq)
                if kind == .inserted, !isUnfilteredList, !wasLoaded, totalCount >= 0 {
                    mutateProjection { $0.updateTotalCount($0.totalCount + 1) }
                }
            } else {
                _ = removeItem(withID: item.id, mutationSeq: mutationSeq)
            }
        }
        prewarmDisplayText(for: changed)
    }

    @discardableResult
    private func applyCommittedRemovals(_ ids: Set<UUID>, mutationSeq: Int64) -> Bool {
        let accepted = Set(ids.filter {
            mutationSeq > (listState.mutationSeq(for: $0) ?? -1) &&
                contentRevisionRegistry.acceptsHistoryChange(itemID: $0, mutationSeq: mutationSeq)
        })
        guard !accepted.isEmpty else { return false }
        _ = invalidateKnownContentRevisions(itemIDs: accepted, mutationSeq: mutationSeq)
        suppressedItemIDs.subtract(accepted)
        // Only a complete, settled projection identifies every matching row. A partial page or
        // pending query cannot turn the global deletion set into an exact filtered total.
        let completeFilteredCount: Int? = hasActiveFilters && searchCoverage == .complete &&
            totalCount == loadedCount && !requests.replacementIsPending &&
            !requests.isLoading && !requests.hasPendingPage ? totalCount : nil
        invalidateInFlightProjectionWorkForDeletion()
        let projected = Set(accepted.filter { listState.acceptsHistoryChange(itemID: $0, mutationSeq: mutationSeq) })
        mutateProjection {
            let removedCount = $0.removeItems(withIDs: projected, mutationSeq: mutationSeq)
            if let completeFilteredCount {
                $0.updateTotalCount(completeFilteredCount - removedCount, mutationSeq: mutationSeq)
            }
        }
        var contexts = searchMatchContexts
        for id in projected { contexts.removeValue(forKey: id) }
        if contexts.count != searchMatchContexts.count { searchMatchContexts = contexts }
        reconcileSelectionAfterProjectionReplacement()
        if hasActiveFilters { refreshSearchAfterHistoryChange() }
        return true
    }

    /// Old rows remain actionable while the gap snapshot is in flight. Cover every identity
    /// they can hand to a new resource owner, as well as existing off-list owners and Undo.
    private func resnapshotHistory() async {
        requests.cancel()
        let version = requests.version
        let retainedIDs = Set(listState.items.map(\.id))
            .union(retainedContentItemIDs?() ?? []).union(suppressedItemIDs)
        let readID = UUID()
        activeHistoryReads[readID] = HistoryReadChanges(protecting: retainedIDs)
        defer { activeHistoryReads.removeValue(forKey: readID) }
        protectRetainedContent()
        do {
            if !retainedIDs.isEmpty {
                let snapshot = try await service.fetchHistoryItems(itemIDs: retainedIDs)
                _ = invalidateKnownContentRevisions(
                    itemIDs: snapshot.missingItemIDs, mutationSeq: snapshot.mutationSeq
                )
                mergeKnownContentRevisions(snapshot.items, mutationSeq: snapshot.mutationSeq)
                if let pending = pendingDeletion,
                   snapshot.mutationSeq >= (pending.mutationSeq ?? -1) {
                    if let item = snapshot.items.first(where: { $0.id == pending.item.id }) {
                        reconcilePendingDeletion(with: item, mutationSeq: snapshot.mutationSeq)
                    } else if snapshot.missingItemIDs.contains(pending.item.id),
                              contentRevisionRegistry.isDeleted(itemID: pending.item.id) {
                        discardPendingDeletion()
                    }
                }
            }
            guard requests.isCurrent(version) else { return }
            if isUnfilteredList {
                let limit = max(Self.initialPageSize, listState.unpinnedItems.count)
                let task = requests.replace { [self] currentVersion in
                    await loadRecent(version: currentVersion, limit: limit)
                }
                await task.value
            } else {
                refreshSearchAfterHistoryChange()
            }
        } catch {
            reportFetchFailure(String(localized: "Loading history failed"), error)
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

    private func scheduleStorageStatsRefresh() {
        storageStatsRefreshTask?.cancel()
        let mutationSeq = latestHistoryMutationSeq
        storageStatsRefreshTask = Task {
            try? await Task.sleep(nanoseconds: timing.recentAppsRefreshDelayNs)
            guard !Task.isCancelled, isUnfilteredList else { return }
            do {
                let stats = try await service.getStorageStats()
                guard !Task.isCancelled, isUnfilteredList, mutationSeq == latestHistoryMutationSeq else { return }
                settingsViewModel.storageStats = stats
            } catch {
                ScopyLog.app.warning("Failed to refresh storage statistics: \(error.localizedDescription, privacy: .private)")
            }
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
        guard isUnfilteredList else { return }
        let task = requests.replace { [self] version in
            await loadRecent(version: version)
        }
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func loadRecent(version currentVersion: HistoryRequestLifecycle.Version, limit: Int = initialPageSize) async {
        cancelTask(&storageDetailsTask)
        guard shouldApplyLoadResult(version: currentVersion) else { return }

        fetchFailureMessage = nil

        do {
            let startTime = CFAbsoluteTimeGetCurrent()

            let readID = UUID()
            let read = HistoryReadChanges()
            activeHistoryReads[readID] = read
            defer { activeHistoryReads.removeValue(forKey: readID) }
            let snapshot = try await service.fetchHistoryPage(limit: limit, after: nil)
            guard shouldApplyLoadResult(version: currentVersion) else { return }
            let fetchedItems = acceptedSnapshotItems(snapshot.pinnedItems + snapshot.items, mutationSeq: snapshot.mutationSeq)
            mergeKnownContentRevisions(snapshot.pinnedItems + snapshot.items, mutationSeq: snapshot.mutationSeq)
            let acceptedIDs = Set(read.changedItemIDs.filter { !suppressedItemIDs.contains($0) && contentRevisionRegistry.acceptsProjection(itemID: $0) })
            searchMatchContexts.removeAll(keepingCapacity: true)
            mutateProjection {
                $0.replaceRecentPage(items: fetchedItems, total: snapshot.total,
                                     continuingAfter: snapshot.nextCursor, mutationSeq: snapshot.mutationSeq)
                read.merge(after: snapshot.mutationSeq, into: &$0, accepting: acceptedIDs.contains)
            }
            applyThumbnails(from: read)
            reconcileSelectionAfterProjectionReplacement()
            activeHistoryReads.removeValue(forKey: readID)
            prewarmDisplayText(for: listState.items)
            searchCoverage = .complete
            lastLoadedAt = Date()

            // Load latency should reflect "first screen ready" rather than unrelated background work.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Task { await PerformanceMetrics.shared.recordLoadLatency(elapsedMs) }

            let stats = try await service.getStorageStats()
            guard shouldApplyLoadResult(version: currentVersion) else { return }

            settingsViewModel.storageStats = stats
            scheduleStorageDetailsRefresh(version: currentVersion)
        } catch {
            guard shouldApplyLoadResult(version: currentVersion) else { return }
            reportFetchFailure(String(localized: "Loading history failed"), error)
            ScopyLog.app.error("Failed to load items: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func shouldApplyLoadResult(version: HistoryRequestLifecycle.Version) -> Bool {
        requests.isCurrent(version) && isUnfilteredList
    }

    private func applyThumbnails(from read: HistoryReadChanges) {
        for thumbnail in read.thumbnails.values {
            applyThumbnail(thumbnail.path, toItemID: thumbnail.itemID,
                           expectedType: thumbnail.expectedType,
                           expectedContentHash: thumbnail.expectedContentHash)
        }
    }

    private func applyThumbnail(
        _ thumbnailPath: String,
        toItemID itemID: UUID,
        expectedType: ClipboardItemType,
        expectedContentHash: String
    ) {
        guard let index = indexOfItem(withID: itemID) else { return }
        let existing = items[index]
        guard existing.type == expectedType,
              existing.contentHash == expectedContentHash,
              existing.thumbnailPath != thumbnailPath else { return }
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
            storageRef: existing.storageRef,
            useCount: existing.useCount
        )
        setItemIfChanged(at: index, to: updated)
    }

    private func scheduleStorageDetailsRefresh(version: HistoryRequestLifecycle.Version) {
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

    /// Rows before the end of the loaded page start the next fetch, so the page is usually applied
    /// before the user reaches the end trigger.
    static let loadMorePrefetchRows = 40

    func rowDidAppear(itemID: UUID) {
        guard canLoadMore, !isLoading, !requests.hasPendingPage else { return }
        guard let index = indexOfItem(withID: itemID), index >= loadedCount - Self.loadMorePrefetchRows else { return }
        Task { await loadMore() }
    }

    /// Rows applied per chunk; chunks are 20 ms apart so a page costs a few short List updates
    /// instead of one long one while the user is still scrolling. Every update makes the table
    /// re-query all row heights, so fewer, larger chunks cost less than many small ones.
    static let loadMoreApplyChunkRows = 50

    func loadMore() async {
        ScrollPerformanceProfile.shared.incrementCounter(name: "list.load_more_attempt")
        // After a failure the rows may not belong to the current request; paging waits for a retry.
        await requests.paginate(when: canLoadMore && fetchFailureMessage == nil) { [self] currentVersion in
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
                        let readID = UUID()
                        activeHistoryReads[readID] = HistoryReadChanges()
                        defer { activeHistoryReads.removeValue(forKey: readID) }
                        let result = try await service.search(query: request)
                        guard requests.isCurrent(currentVersion) else { return }
                        guard await applyRefinedSearchPage(with: result, version: currentVersion) else { return }
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
                        // Continue the calibrated ranking. Returning to the interactive prefilter
                        // mixes two result orders and forces a large replacement on the next page.
                        forceFullFuzzy: searchMode == .fuzzy || searchMode == .fuzzyPlus,
                        limit: Self.loadMorePageSize,
                        offset: pagingOffset(loadedCount, countsPinned: true)
                    )
                    ScrollPerformanceProfile.shared.incrementCounter(
                        name: "list.pagination_request"
                    )
                    let readID = UUID()
                    activeHistoryReads[readID] = HistoryReadChanges()
                    defer { activeHistoryReads.removeValue(forKey: readID) }
                    let result = try await service.search(query: request)
                    guard requests.isCurrent(currentVersion) else { return }
                    prewarmDisplayText(for: acceptedSearchHits(result.hits, mutationSeq: result.mutationSeq).map(\.item))
                    guard await appendSearchPage(with: result, version: currentVersion) else { return }
                    searchCoverage = result.coverage
                } else {
                    ScrollPerformanceProfile.shared.incrementCounter(
                        name: "list.pagination_request"
                    )
                    guard let cursor = listState.recentCursor else { return }
                    let readID = UUID()
                    let read = HistoryReadChanges()
                    activeHistoryReads[readID] = read
                    defer { activeHistoryReads.removeValue(forKey: readID) }
                    let page = try await service.fetchHistoryPage(limit: Self.loadMorePageSize, after: cursor)
                    guard requests.isCurrent(currentVersion) else { return }
                    prewarmDisplayText(for: excludingKnownDeletedItems(page.items))
                    var start = 0
                    repeat {
                        if start > 0 {
                            try? await Task.sleep(nanoseconds: 20_000_000)
                            guard requests.isCurrent(currentVersion) else { return }
                        }
                        let end = min(page.items.count, start + Self.loadMoreApplyChunkRows)
                        let chunk = page.items[start..<end]
                        let continuation = end == page.items.count
                            ? page.nextCursor : chunk.last.map(RecentHistoryCursor.init)
                        let accepted = acceptedSnapshotItems(Array(chunk), mutationSeq: page.mutationSeq)
                        mergeKnownContentRevisions(Array(chunk), mutationSeq: page.mutationSeq)
                        let acceptedIDs = Set(read.changedItemIDs.filter {
                            !suppressedItemIDs.contains($0) && contentRevisionRegistry.acceptsProjection(itemID: $0)
                        })
                        mutateProjection {
                            $0.appendRecentPage(items: accepted, continuingAfter: continuation,
                                                mutationSeq: page.mutationSeq)
                            read.merge(after: page.mutationSeq, into: &$0, accepting: acceptedIDs.contains)
                            $0.updateTotalCount(page.total, mutationSeq: page.mutationSeq)
                        }
                        applyThumbnails(from: read)
                        reconcileSelectionAfterProjectionReplacement()
                        start = end
                    } while start < page.items.count
                    searchCoverage = .complete
                }
            } catch {
                guard requests.isCurrent(currentVersion) else { return }
                if searchCoverage.isStagedRefine {
                    searchCoverage = .incomplete
                }
                reportFetchFailure(String(localized: "Loading more failed"), error)
                ScopyLog.app.error("Failed to load more: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Search

    /// The current rows stay on screen until the versioned replacement arrives: clearing them per
    /// keystroke emptied the List and rebuilt it twice more when the results landed. A failed search
    /// also keeps them, marks coverage incomplete and reports the failure in the footer, so a
    /// failure never reads as "No results". A valid candidate without renderable evidence is not a
    /// failed search and keeps the row with its ordinary metadata.
    func search() {
        projectionIdentity = UUID()
        startSearch()
    }

    /// Starts a first-page request without changing which query owns the displayed rows. Both
    /// user searches and event refreshes use this path; only the user search replaces identity.
    private func startSearch() {
        cancelTask(&storageDetailsTask)
        fetchFailureMessage = nil

        if isUnfilteredList {
            requests.replace { [self] version in
                await loadRecent(version: version)
            }
            return
        }

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
        requests.replace { [self] currentVersion in
            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let debounceNs = effectiveSearchDebounceNs(for: query)
            try? await Task.sleep(nanoseconds: debounceNs)
            guard requests.isCurrent(currentVersion) else { return }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                let readID = UUID()
                activeHistoryReads[readID] = HistoryReadChanges()
                defer { activeHistoryReads.removeValue(forKey: readID) }
                let result = try await service.search(query: request)
                guard requests.isCurrent(currentVersion) else { return }
                let prefilterItems = acceptedSearchHits(result.hits, mutationSeq: result.mutationSeq).map(\.item)
                prewarmDisplayText(for: prefilterItems)
                let refineFollows = (request.mode == .fuzzy || request.mode == .fuzzyPlus)
                    && result.coverage.isStagedRefine
                // An empty prefilter page is not an answer while the full pass is still coming:
                // publishing it would flash "No results" until the refine brings rows back.
                let deferredEmptyPage = refineFollows && prefilterItems.isEmpty ? result : nil
                if deferredEmptyPage == nil {
                    replaceSearchPage(with: result)
                    searchCoverage = result.coverage
                }

                var pendingRefine: Task<Void, Never>?
                if refineFollows {
                    let refine = requests.refine(version: currentVersion) { [self] in
                        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        let delayNs: UInt64 = trimmed.count <= 2 ? timing.refineShortQueryDelayNs : timing.refineLongQueryDelayNs
                        try? await Task.sleep(nanoseconds: delayNs)
                        guard requests.isCurrent(currentVersion) else { return }

                        let refineRequest = SearchRequest(
                            query: request.query,
                            mode: request.mode,
                            sortMode: request.sortMode,
                            appFilter: request.appFilter,
                            typeFilter: request.typeFilter,
                            typeFilters: request.typeFilters,
                            forceFullFuzzy: true,
                            limit: Self.initialPageSize,
                            offset: 0
                        )

                        do {
                            let readID = UUID()
                            activeHistoryReads[readID] = HistoryReadChanges()
                            defer { activeHistoryReads.removeValue(forKey: readID) }
                            let refined = try await service.search(query: refineRequest)
                            guard requests.isCurrent(currentVersion) else { return }

                            prewarmDisplayText(for: acceptedSearchHits(refined.hits, mutationSeq: refined.mutationSeq).map(\.item))
                            replaceSearchPage(with: refined, skippingIdenticalRefine: true)
                            searchCoverage = refined.coverage
                        } catch {
                            guard requests.isCurrent(currentVersion) else { return }
                            if deferredEmptyPage == nil, !searchCoverage.isStagedRefine {
                                return
                            }
                            searchCoverage = .incomplete
                            reportFetchFailure(String(localized: "Search failed"), error)
                            ScopyLog.app.warning("Refine search failed: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                    if deferredEmptyPage != nil { pendingRefine = refine }
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                Task { await PerformanceMetrics.shared.recordSearchLatency(elapsedMs) }
                // With the prefilter page deferred, loading lasts until the refine lands: the empty
                // state shows only for a final empty result, and the previous query's rows on
                // screen cannot start paging for this one.
                await pendingRefine?.value
            } catch {
                guard requests.isCurrent(currentVersion) else { return }
                searchCoverage = .incomplete
                reportFetchFailure(String(localized: "Search failed"), error)
                ScopyLog.app.error("Search failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Re-runs the current search after a capture, content change or deletion. Within the first
    /// page, or while a search for a new query is still running, it restarts the first page. Past
    /// it, one request at offset 0 covers every loaded row, so the change lands without collapsing
    /// the rows the user paged through back to the first page. The refresh holds the paging slot,
    /// so a `loadMore` waits for it instead of reading an offset the change just moved.
    private func refreshSearchAfterHistoryChange() {
        guard loadedCount > Self.initialPageSize, !requests.replacementIsPending else {
            startSearch()
            return
        }
        let request = SearchRequest(
            query: searchQuery,
            mode: searchMode,
            sortMode: ftsSortMode,
            appFilter: appFilter,
            typeFilter: typeFilter,
            typeFilters: typeFilters,
            // The loaded rows past the first page carry the calibrated ranking.
            forceFullFuzzy: searchMode == .fuzzy || searchMode == .fuzzyPlus,
            limit: pagingOffset(loadedCount, countsPinned: true),
            offset: 0
        )
        let debounceNs = effectiveSearchDebounceNs(for: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        requests.refresh { [self] currentVersion in
            // A burst of events costs one request.
            try? await Task.sleep(nanoseconds: debounceNs)
            guard requests.isCurrent(currentVersion) else { return }
            do {
                let readID = UUID()
                activeHistoryReads[readID] = HistoryReadChanges()
                defer { activeHistoryReads.removeValue(forKey: readID) }
                let result = try await service.search(query: request)
                guard requests.isCurrent(currentVersion) else { return }
                prewarmDisplayText(for: acceptedSearchHits(result.hits, mutationSeq: result.mutationSeq).map(\.item))
                replaceSearchPage(with: result, skippingIdenticalRefine: true)
                searchCoverage = result.coverage
                fetchFailureMessage = nil
            } catch {
                guard requests.isCurrent(currentVersion) else { return }
                searchCoverage = .incomplete
                reportFetchFailure(String(localized: "Search failed"), error)
                ScopyLog.app.error("Search refresh failed: \(error.localizedDescription, privacy: .private)")
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
                return String(localized: "Relevance")
            case .recent:
                return String(localized: "Recent")
            }
        }
        return String(localized: "Recent")
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
            reportActionFailure(error)
        }
    }

    func selectOptimizedForCodex(_ item: ClipboardItemDTO) async {
        do {
            try await service.copyToClipboardOptimizedForCodex(itemID: item.id)
            closePanelHandler?()
            // Only paste once the pasteboard is known to hold this item. Pasting after a failed
            // write would deliver whatever the clipboard held before.
            pasteAfterCopyHandler?()
        } catch {
            ScopyLog.app.error("Codex-optimized copy failed: \(error.localizedDescription, privacy: .private)")
            reportActionFailure(error)
        }
    }

    func reportActionFailure(_ error: Error) {
        reportActionFailure(message: Self.failureReason(error))
    }

    func reportActionFailure(message: String) {
        actionErrorMessage = message
        actionErrorClearTask?.cancel()
        actionErrorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.actionErrorVisibleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.actionErrorMessage = nil
        }
    }

    func clearActionError() {
        actionErrorClearTask?.cancel()
        actionErrorClearTask = nil
        actionErrorMessage = nil
    }

    private func reportFetchFailure(_ operation: String, _ error: Error) {
        fetchFailureMessage = "\(operation): \(Self.failureReason(error))"
    }

    private static func failureReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func sendViaAirDrop(_ item: ClipboardItemDTO) async {
        let urls = await resolvedFileURLs(for: item)
        guard !urls.isEmpty else {
            reportActionFailure(message: String(localized: "No files to send via AirDrop"))
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            ScopyLog.app.error("AirDrop sharing service is unavailable")
            reportActionFailure(message: String(localized: "AirDrop is unavailable"))
            return
        }
        service.perform(withItems: urls)
    }

    func openContainingFolder(_ item: ClipboardItemDTO) async {
        let urls = realFileURLs(for: item)
        guard !urls.isEmpty else {
            reportActionFailure(message: String(localized: "No file to show in Finder"))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// A hotkey reopen after the panel was closed longer than
    /// `PanelReopenSearchResetPolicy.staleIntervalSeconds` starts over, with or without a query: no
    /// selection or query, the list's first page (the rows paged in before are dropped), scrolled
    /// to the top.
    func resetForStalePanelReopen() {
        selectedID = nil
        lastSelectionSource = .programmatic
        searchQuery = ""
        search()
        // The caller opens the panel next; scroll once it is on screen.
        DispatchQueue.main.async { [weak self] in self?.scrollListToTop?() }
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
            reportActionFailure(error)
        }
    }

    /// Removes the row at once and sends the backend delete after `Timing.undoDeletionWindowNs`,
    /// so the footer or ⌘Z can undo it. One deletion is pending at a time: the next delete, a
    /// clear, or closing the panel commits the previous one first. Local suppression keeps events,
    /// searches and loads from reviving the row meanwhile, and closes its pinned preview.
    func delete(_ item: ClipboardItemDTO) async {
        guard !isTerminating else { return }
        // Take the undo slot over before any await: a delete that starts while the previous one
        // is being sent must not be overwritten when this call resumes.
        let previous = pendingDeletion
        previous?.commit.cancel()
        pendingDeletion = nil
        suppressedItemIDs.insert(item.id)
        contentRevisionReconciliationToken &+= 1
        let index = indexOfItem(withID: item.id) ?? 0
        let predecessorID = index > 0 ? listState.item(at: index - 1)?.id : nil
        let successorID = listState.item(at: index + 1)?.id
        let evidence = searchMatchContexts[item.id]
        _ = removeItem(withID: item.id)
        let token = UUID()
        let window = timing.undoDeletionWindowNs
        pendingDeletion = PendingDeletion(
            item: item,
            mutationSeq: contentRevisionRegistry.mutationSeq(for: item.id),
            useCountAtDeletion: item.useCount,
            token: token,
            projection: projectionIdentity,
            index: index,
            predecessorID: predecessorID,
            successorID: successorID,
            evidence: evidence,
            commit: Task { [weak self] in
                try? await Task.sleep(nanoseconds: window)
                guard !Task.isCancelled else { return }
                await self?.commitPendingDeletion(token: token)
            }
        )
        if let previous { await sendDeletion(previous) }
    }

    func undoPendingDeletion() async {
        guard let pending = pendingDeletion else { return }
        pending.commit.cancel()
        pendingDeletion = nil
        revive(pending)
    }

    /// Sends the pending backend delete now instead of at the end of the undo window.
    func commitPendingDeletionNow() async {
        guard let pending = pendingDeletion else { return }
        pending.commit.cancel()
        pendingDeletion = nil
        await sendDeletion(pending)
    }

    /// Normal Quit waits for both the undo slot and deletes already sent by a timer or panel close.
    /// A failed delete restores its row and keeps the app open so the user can retry.
    func prepareForTermination() async -> Bool {
        isTerminating = true
        let failuresBeforeDrain = deletionFailureGeneration
        repeat {
            await commitPendingDeletionNow()
            let tasks = Array(inFlightDeletions.values)
            for task in tasks { _ = await task.value }
        } while pendingDeletion != nil || !inFlightDeletions.isEmpty
        let succeeded = deletionFailureGeneration == failuresBeforeDrain
        if !succeeded { isTerminating = false }
        return succeeded
    }

    private func commitPendingDeletion(token: UUID) async {
        guard let pending = pendingDeletion, pending.token == token else { return }
        pendingDeletion = nil
        await sendDeletion(pending)
    }

    /// The backend delete of a row whose undo window is over; the slot has already moved on, so a
    /// newer pending deletion is never touched here.
    @discardableResult
    private func sendDeletion(_ pending: PendingDeletion) async -> Bool {
        if let existing = inFlightDeletions[pending.token] { return await existing.value }
        let task = Task { @MainActor in
            let readID = UUID()
            let read = HistoryReadChanges(protecting: [pending.item.id])
            activeHistoryReads[readID] = read
            defer {
                activeHistoryReads.removeValue(forKey: readID)
                inFlightDeletions.removeValue(forKey: pending.token)
            }
            do {
                let snapshot = try await service.delete(
                    itemID: pending.item.id, expectedUseCount: pending.useCountAtDeletion
                )
                if snapshot.missingItemIDs.contains(pending.item.id) {
                    let applied = applyCommittedRemovals([pending.item.id], mutationSeq: snapshot.mutationSeq)
                    if !applied, hasActiveFilters { refreshSearchAfterHistoryChange() }
                } else if snapshot.requestedItemIDs.contains(pending.item.id),
                          let item = snapshot.items.first(where: { $0.id == pending.item.id }) {
                    mergeKnownContentRevisions([item], mutationSeq: snapshot.mutationSeq)
                    restoreAfterDeletionDecision(pending, item: item, mutationSeq: snapshot.mutationSeq, changes: read)
                } else {
                    throw DeletionSnapshotError.missingRequestedIdentity
                }
                return true
            } catch {
                deletionFailureGeneration &+= 1
                ScopyLog.app.error("Delete failed: \(error.localizedDescription, privacy: .private)")
                restoreAfterDeletionDecision(pending, item: pending.item, mutationSeq: pending.mutationSeq, changes: read)
                reportActionFailure(error)
                return false
            }
        }
        inFlightDeletions[pending.token] = task
        return await task.value
    }

    private enum DeletionSnapshotError: LocalizedError {
        case missingRequestedIdentity

        var errorDescription: String? {
            String(localized: "The deletion result could not be verified.")
        }
    }

    /// A newer copy can win the transaction after the Undo slot has moved on. Restore that
    /// version without treating a declined deletion as a failure, and retain later facts.
    private func restoreAfterDeletionDecision(
        _ pending: PendingDeletion,
        item: ClipboardItemDTO,
        mutationSeq: Int64?,
        changes: HistoryReadChanges
    ) {
        var restored = pending
        restored.item = changes.item(withID: item.id, after: mutationSeq ?? -1) ?? item
        restored.mutationSeq = [mutationSeq, changes.mutationSeq(for: item.id)].compactMap { $0 }.max()
        if pending.item.plainText != restored.item.plainText || pending.item.note != restored.item.note {
            restored.evidence = nil
        }
        revive(restored)
        if !contentRevisionRegistry.isDeleted(itemID: item.id), !hasSemanticSearchQuery,
           matchesCurrentFilters(restored.item) {
            _ = upsertRecentItem(restored.item)
        }
        applyThumbnails(from: changes)
        if hasActiveFilters { refreshSearchAfterHistoryChange() }
    }

    /// The backend deleted the pending row itself; there is nothing left to send or undo.
    private func discardPendingDeletion() {
        pendingDeletion?.commit.cancel()
        if let pendingDeletion { suppressedItemIDs.remove(pendingDeletion.item.id) }
        pendingDeletion = nil
    }

    /// A pending deletion is undone implicitly when the backend publishes the same row again
    /// (identical content copied inside the window and deduplicated onto this row): committing
    /// it would delete what the user just copied.
    private func reconcilePendingDeletion(with commit: CommittedHistoryChange) {
        guard let pending = pendingDeletion,
              commit.mutationSeq > (pending.mutationSeq ?? -1) else { return }
        switch commit.change {
        case .itemsChanged(let items, _):
            guard let item = items.first(where: { $0.id == pending.item.id }) else { return }
            reconcilePendingDeletion(with: item, mutationSeq: commit.mutationSeq)
        case .itemsRemoved(let ids), .itemsCleared(let ids):
            if ids.contains(pending.item.id) { discardPendingDeletion() }
        }
    }

    /// The counter survives a journal gap and still advances when MAX keeps lastUsedAt fixed.
    /// Its deletion-time baseline never changes when metadata refreshes the retained row.
    private func reconcilePendingDeletion(with item: ClipboardItemDTO, mutationSeq: Int64) {
        guard var pending = pendingDeletion, pending.item.id == item.id,
              mutationSeq >= (pending.mutationSeq ?? -1) else { return }
        if pending.item.plainText != item.plainText || pending.item.note != item.note {
            pending.evidence = nil
        }
        pending.item = item
        pending.mutationSeq = mutationSeq
        guard item.useCount > pending.useCountAtDeletion else {
            pendingDeletion = pending
            return
        }
        pending.commit.cancel()
        pendingDeletion = nil
        revive(pending)
        if pending.projection == projectionIdentity, !hasSemanticSearchQuery, matchesCurrentFilters(item) {
            _ = upsertRecentItem(item)
        }
    }

    /// Lifts local suppression and restores the latest row retained by the undo slot.
    /// A committed deletion remains authoritative even if an older delete attempt failed.
    private func revive(_ pending: PendingDeletion) {
        suppressedItemIDs.remove(pending.item.id)
        contentRevisionReconciliationToken &+= 1
        guard !contentRevisionRegistry.isDeleted(itemID: pending.item.id),
              pending.projection == projectionIdentity else { return }
        let index: Int
        if let successorID = pending.successorID, let successor = indexOfItem(withID: successorID) {
            index = successor
        } else if let predecessorID = pending.predecessorID, let predecessor = indexOfItem(withID: predecessorID) {
            index = predecessor + 1
        } else {
            index = pending.index
        }
        mutateProjection { $0.insertItem(pending.item, at: index, mutationSeq: pending.mutationSeq) }
        if let evidence = pending.evidence {
            searchMatchContexts[pending.item.id] = evidence
        }
        lastSelectionSource = .programmatic
        selectedID = pending.item.id
    }

    /// A row whose backend delete is still deferred keeps its place in the backend's ordering, so
    /// paging the projection it was removed from starts one row later.
    private func pagingOffset(_ loaded: Int, countsPinned: Bool) -> Int {
        guard let pending = pendingDeletion, pending.projection == projectionIdentity,
              countsPinned || !pending.item.isPinned else { return loaded }
        return loaded + 1
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
        await commitPendingDeletionNow()
        do {
            try await service.clearAll()
            lastSelectionSource = .programmatic
            selectedID = nil
        } catch {
            ScopyLog.app.error("Clear failed: \(error.localizedDescription, privacy: .private)")
            reportActionFailure(error)
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
        let rows = displayOrderItems
        guard !rows.isEmpty else { return }
        lastSelectionSource = .keyboard
        keyboardSelectionPointerAnchor = NSEvent.mouseLocation
        if let selectedID,
           let index = rows.firstIndex(where: { $0.id == selectedID }),
           index < rows.count - 1 {
            self.selectedID = rows[index + 1].id
        } else {
            self.selectedID = rows.first?.id
        }
    }

    func highlightPrevious() {
        let rows = displayOrderItems
        guard !rows.isEmpty else { return }
        lastSelectionSource = .keyboard
        keyboardSelectionPointerAnchor = NSEvent.mouseLocation
        if let selectedID,
           let index = rows.firstIndex(where: { $0.id == selectedID }),
           index > 0 {
            self.selectedID = rows[index - 1].id
        } else {
            self.selectedID = rows.last?.id
        }
    }

    func deleteSelectedItem() async {
        let rows = displayOrderItems
        guard let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) else { return }

        let nextID: UUID?
        if index < rows.count - 1 {
            nextID = rows[index + 1].id
        } else if index > 0 {
            nextID = rows[index - 1].id
        } else {
            nextID = nil
        }

        await delete(rows[index])

        lastSelectionSource = .programmatic
        self.selectedID = nextID
    }

    func selectCurrent() async {
        guard let selectedID, let item = displayOrderItems.first(where: { $0.id == selectedID }) else { return }
        await select(item)
    }

    /// ⌘1–9: the n-th displayed row with ⏎ semantics (copy and close; a failed copy keeps the
    /// panel open). Collapsed pinned rows are not displayed, so they take no slot.
    func selectQuickSlot(_ slot: Int) async {
        let rows = displayOrderItems
        guard slot >= 1, slot <= min(9, rows.count) else { return }
        await select(rows[slot - 1])
    }

    /// While ⌘ is held the first nine displayed rows show ⌘n instead of their time; the hints
    /// follow the displayed order for as long as they are up.
    func setQuickSlotHintsVisible(_ visible: Bool) {
        quickSlotHintsVisible = visible
        fanOutQuickSlots()
    }

    private func fanOutQuickSlots() {
        var slots: [UUID: Int] = [:]
        if quickSlotHintsVisible {
            let leading = isPinnedCollapsed ? [] : Array(pinnedItems.prefix(9))
            let rows = leading + unpinnedItems.prefix(9 - leading.count)
            for (index, item) in rows.enumerated() {
                slots[item.id] = index + 1
            }
        }
        rowLiveState.updateQuickSlots(slots)
    }

    // MARK: - Private

    // Prewarm a fetched page once, before publishing its first chunk. These caches cancel
    // superseded requests, so prewarming each chunk would discard unfinished work.
    private func prewarmDisplayText(for items: [ClipboardItemDTO]) {
        guard !items.isEmpty else { return }
        ClipboardItemDisplayText.shared.prewarm(items: items)
        HistoryItemPresentationCache.shared.prewarm(items: items)
    }

    private func excludingKnownDeletedItems(
        _ items: [ClipboardItemDTO]
    ) -> [ClipboardItemDTO] {
        items.filter { !suppressedItemIDs.contains($0.id) && contentRevisionRegistry.acceptsProjection(itemID: $0.id) }
    }

    private func mergeKnownContentRevisions(
        _ items: [ClipboardItemDTO],
        mutationSeq: Int64
    ) {
        protectRetainedContent()
        let accepted = items.filter { contentRevisionRegistry.acceptsSnapshot(itemID: $0.id, mutationSeq: mutationSeq) }
        for read in activeHistoryReads.values { read.record(items: accepted, mutationSeq: mutationSeq) }
        guard contentRevisionRegistry.merge(items: accepted, mutationSeq: mutationSeq) else { return }
        contentRevisionReconciliationToken &+= 1
    }

    @discardableResult
    private func invalidateKnownContentRevisions(itemIDs: Set<UUID>, mutationSeq: Int64) -> Int {
        protectRetainedContent()
        let accepted = Set(itemIDs.filter { contentRevisionRegistry.acceptsHistoryChange(itemID: $0, mutationSeq: mutationSeq) })
        for read in activeHistoryReads.values { read.recordMissing(itemIDs: accepted, mutationSeq: mutationSeq) }
        let newlyDeletedCount = contentRevisionRegistry.invalidate(itemIDs: accepted, mutationSeq: mutationSeq)
        guard newlyDeletedCount > 0 else { return 0 }
        contentRevisionReconciliationToken &+= 1
        return newlyDeletedCount
    }

    private func protectRetainedContent() {
        var protectedIDs = (retainedContentItemIDs?() ?? []).union(suppressedItemIDs)
        for read in activeHistoryReads.values { protectedIDs.formUnion(read.protectedItemIDs) }
        contentRevisionRegistry.protect(itemIDs: protectedIDs)
        for id in protectedIDs {
            guard let item = listState.item(withID: id), let version = listState.mutationSeq(for: id) else { continue }
            _ = contentRevisionRegistry.merge(items: [item], mutationSeq: version)
        }
    }

    /// A search page continues from an offset, which a deletion shifts. Recent pages continue from
    /// a key and merge committed versions without restarting the read.
    private func invalidateInFlightProjectionWorkForDeletion() {
        guard !isUnfilteredList else { return }
        requests.cancel()
        cancelTask(&storageDetailsTask)
    }

    private func resolvedFileURLs(for item: ClipboardItemDTO) async -> [URL] {
        if let urls = try? await service.fileURLs(itemID: item.id), !urls.isEmpty {
            return urls
        }
        return FilePreviewSupport.fileURLs(from: item.plainText)
    }

    private func realFileURLs(for item: ClipboardItemDTO) -> [URL] {
        switch item.type {
        case .file:
            return FilePreviewSupport.fileURLs(from: item.plainText)
        case .image:
            if let storageRef = item.storageRef, !storageRef.isEmpty {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: storageRef, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return [URL(fileURLWithPath: storageRef)]
                }
            }
            return FilePreviewSupport.fileURLs(from: item.plainText)
        case .text, .rtf, .html, .other:
            return []
        }
    }

    private func indexOfItem(withID id: UUID) -> Int? {
        listState.indexOfItem(withID: id)
    }

    private func acceptedSnapshotItems(_ items: [ClipboardItemDTO], mutationSeq: Int64) -> [ClipboardItemDTO] {
        items.filter {
            !suppressedItemIDs.contains($0.id) &&
                contentRevisionRegistry.acceptsSnapshot(itemID: $0.id, mutationSeq: mutationSeq)
        }
    }

    private func acceptedSearchHits(_ hits: [SearchResultHit], mutationSeq: Int64) -> [SearchResultHit] {
        hits.compactMap { hit in
            let id = hit.item.id
            guard !suppressedItemIDs.contains(id) else { return nil }
            if contentRevisionRegistry.acceptsSnapshot(itemID: id, mutationSeq: mutationSeq) { return hit }
            guard !contentRevisionRegistry.isDeleted(itemID: id) else { return nil }
            let latestRead = activeHistoryReads.values.max {
                ($0.mutationSeq(for: id) ?? -1) < ($1.mutationSeq(for: id) ?? -1)
            }
            guard let current = latestRead?.item(withID: id, after: mutationSeq) ?? listState.item(withID: id) else {
                return nil
            }
            let sameSearchContent = current.plainText == hit.item.plainText && current.note == hit.item.note
            return SearchResultHit(item: current, matchContext: sameSearchContent ? hit.matchContext : nil)
        }
    }

    private func recordSearchVersions(_ items: [ClipboardItemDTO], snapshotVersion: Int64) {
        mergeKnownContentRevisions(items, mutationSeq: snapshotVersion)
        mutateProjection { state in
            for item in items {
                guard let index = state.indexOfItem(withID: item.id),
                      let known = contentRevisionRegistry.mutationSeq(for: item.id), known > snapshotVersion else { continue }
                _ = state.setItemIfChanged(at: index, to: item, mutationSeq: known)
            }
        }
    }

    private func replaceSearchPage(with result: SearchResultPage, skippingIdenticalRefine: Bool = false) {
        // A row appears once, as on the append path: two hits for one id would trap the evidence
        // map below and give the List two rows with one identity.
        var seenIDs = Set<UUID>()
        let hits = acceptedSearchHits(result.hits, mutationSeq: result.mutationSeq).filter { seenIDs.insert($0.item.id).inserted }
        let resultItems = hits.map(\.item)
        let contexts = Dictionary(
            uniqueKeysWithValues: hits.compactMap { hit in
                hit.matchContext.map { (hit.item.id, $0) }
            }
        )
        // A refine pass that reproduces the prefilter page must not rebuild the List.
        if skippingIdenticalRefine,
           resultItems == listState.items,
           contexts == searchMatchContexts {
            mutateProjection { $0.updatePagination(total: result.total, hasMore: result.hasMore, mutationSeq: result.mutationSeq) }
            recordSearchVersions(resultItems, snapshotVersion: result.mutationSeq)
            return
        }
        // Evidence first: rows created for the new page read theirs when they are built.
        searchMatchContexts = contexts
        mutateProjection {
            $0.replacePage(items: resultItems, total: result.total, hasMore: result.hasMore, mutationSeq: result.mutationSeq)
        }
        recordSearchVersions(resultItems, snapshotVersion: result.mutationSeq)
        reconcileSelectionAfterProjectionReplacement()
    }

    private func applyRefinedSearchPage(with result: SearchResultPage, version: HistoryRequestLifecycle.Version) async -> Bool {
        let hits = acceptedSearchHits(result.hits, mutationSeq: result.mutationSeq)
        let existingIDs = Set(items.map(\.id))
        let newHits = hits.filter { !existingIDs.contains($0.item.id) }
        prewarmDisplayText(for: hits.map(\.item))
        // Keep the staged rows, including the visible scroll anchor and selection, present
        // while mounting new rows. Once they exist, commit the full ranking atomically.
        // Replacing a truncated prefix first can temporarily remove the current scroll anchor.
        if !newHits.isEmpty {
            let newIDs = Set(newHits.map { $0.item.id })
            guard await appendSearchPage(with: result, version: version, including: newIDs) else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard requests.isCurrent(version) else { return false }
        replaceSearchPage(with: result, skippingIdenticalRefine: true)
        return true
    }

    private func appendSearchPage(
        with result: SearchResultPage,
        version: HistoryRequestLifecycle.Version,
        including itemIDs: Set<UUID>? = nil
    ) async -> Bool {
        guard requests.isCurrent(version) else { return false }
        let sourceHits = itemIDs.map { ids in result.hits.filter { ids.contains($0.item.id) } } ?? result.hits
        if sourceHits.isEmpty {
            mutateProjection { $0.updatePagination(total: result.total, hasMore: result.hasMore, mutationSeq: result.mutationSeq) }
            return true
        }
        var start = 0
        while start < sourceHits.count {
            guard requests.isCurrent(version) else { return false }
            let end = min(start + Self.loadMoreApplyChunkRows, sourceHits.count)
            let hits = acceptedSearchHits(Array(sourceHits[start..<end]), mutationSeq: result.mutationSeq)
            let resultItems = hits.map(\.item)

            // Publish each chunk's evidence and rows in the same actor turn. Yield only after
            // both are ready, so a newly visible search result never loses its match evidence.
            var mergedContexts = searchMatchContexts
            for hit in hits {
                if let matchContext = hit.matchContext {
                    mergedContexts[hit.item.id] = matchContext
                }
            }
            searchMatchContexts = mergedContexts
            ScrollPerformanceProfile.shared.incrementCounter(name: "list.pagination_search_chunk")
            mutateProjection {
                $0.appendPage(
                    items: resultItems,
                    total: result.total,
                    hasMore: end < sourceHits.count || result.hasMore,
                    mutationSeq: result.mutationSeq
                )
            }
            recordSearchVersions(resultItems, snapshotVersion: result.mutationSeq)
            start = end
            if start < sourceHits.count {
                // Match recent-history paging: allow layout to commit before the next chunk.
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return true
    }

    private func reconcileSelectionAfterProjectionReplacement() {
        guard let selectedID, indexOfItem(withID: selectedID) == nil else { return }
        self.selectedID = nil
        lastSelectionSource = .programmatic
    }

    @discardableResult
    private func setItemIfChanged(at index: Int, to value: ClipboardItemDTO, mutationSeq: Int64? = nil) -> Bool {
        var changed = false
        mutateProjection { changed = $0.setItemIfChanged(at: index, to: value, mutationSeq: mutationSeq) }
        return changed
    }

    @discardableResult
    private func removeItem(withID id: UUID, mutationSeq: Int64? = nil) -> Bool {
        searchMatchContexts.removeValue(forKey: id)
        if selectedID == id {
            selectedID = nil
            lastSelectionSource = .programmatic
        }
        var removed = false
        mutateProjection { removed = $0.removeItem(withID: id, mutationSeq: mutationSeq) }
        return removed
    }

    @discardableResult
    private func upsertRecentItem(_ item: ClipboardItemDTO, mutationSeq: Int64? = nil) -> Bool {
        var changed = false
        mutateProjection { changed = $0.upsertRecentItem(item, mutationSeq: mutationSeq) }
        // A row that moved past the cursor left for a later page, and the selection with it.
        if changed, selectedID == item.id, indexOfItem(withID: item.id) == nil {
            reconcileSelectionAfterProjectionReplacement()
        }
        return changed
    }

    private func effectiveSearchDebounceNs(for query: String) -> UInt64 {
        if query.count <= 2 {
            return max(timing.searchDebounceNs, 16_000_000)
        }
        return timing.searchDebounceNs
    }

    /// The only way the projection changes: applies `change` and then writes each observed cell
    /// only if its value moved, so a pagination-only or total-only update leaves the rows alone.
    private func mutateProjection(_ change: (inout HistoryListState) -> Void) {
        protectRetainedContent()
        change(&listState)
        if projectionGeneration != listState.projectionGeneration {
            projectionGeneration = listState.projectionGeneration
            if quickSlotHintsVisible { fanOutQuickSlots() }
        }
        if totalCount != listState.totalCount { totalCount = listState.totalCount }
        if canLoadMore != listState.canLoadMore { canLoadMore = listState.canLoadMore }
    }

    private func cancelTask(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}
