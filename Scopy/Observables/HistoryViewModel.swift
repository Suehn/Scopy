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

    /// Whether state held for `itemID` outside the list must be torn down.
    ///
    /// Shared by every off-list holder (retained row sessions, the pinned preview window) so they
    /// cannot disagree about what "gone" means. Generation changes are the caller's, because each
    /// holder applies snapshots on its own schedule.
    func invalidates(
        itemID: UUID,
        currentRevision: ClipboardItemContentRevision?,
        clearGenerationChanged: Bool,
        deletionEvictionGenerationChanged: Bool
    ) -> Bool {
        if wasDeleted(itemID) { return true }
        if clearGenerationChanged,
           clearSurvivorSetIsAuthoritative,
           !clearSurvivingItemIDs.contains(itemID) {
            return true
        }
        // A deletion-eviction overflow means the deleted set is no longer authoritative.
        if !clearGenerationChanged, deletionEvictionGenerationChanged { return true }
        if let currentRevision, let known = revision(for: itemID), known != currentRevision {
            return true
        }
        return false
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
        /// How long a deleted row stays undoable before the backend delete is sent.
        var undoDeletionWindowNs: UInt64

        static let production = Timing(
            searchDebounceNs: 0,
            // Long queries refine at once; short ones keep a tiny delay so the page does not flicker.
            refineShortQueryDelayNs: 10_000_000,
            refineLongQueryDelayNs: 0,
            recentAppsRefreshDelayNs: 500_000_000,
            staleLoadRetryDelayNs: 100_000_000,
            undoDeletionWindowNs: 5_000_000_000
        )

        static let tests = Timing(
            searchDebounceNs: 20_000_000,
            refineShortQueryDelayNs: 40_000_000,
            refineLongQueryDelayNs: 40_000_000,
            recentAppsRefreshDelayNs: 20_000_000,
            staleLoadRetryDelayNs: 20_000_000,
            undoDeletionWindowNs: 50_000_000
        )
    }

    private struct PendingDeletion {
        let item: ClipboardItemDTO
        let token: UUID
        /// Which projection the row left and its neighbours there, so undo can put it straight
        /// back even after newer rows were inserted in front.
        let projection: UUID
        let index: Int
        let predecessorID: UUID?
        let successorID: UUID?
        let evidence: SearchMatchContext?
        let commit: Task<Void, Never>
    }

    // MARK: - Properties

    @ObservationIgnored private var service: ClipboardServiceProtocol
    @ObservationIgnored private let settingsViewModel: SettingsViewModel
    @ObservationIgnored private var timing: Timing = .production

    @ObservationIgnored var closePanelHandler: (() -> Void)?
    @ObservationIgnored var pasteAfterCopyHandler: (() -> Void)?
    /// The list keeps the row under its top edge in place across a row change (see
    /// `ListScrollAnchorKeeper`); these bracket every change to the rows.
    @ObservationIgnored var projectionWillChange: (() -> Void)?
    @ObservationIgnored var projectionDidChange: (() -> Void)?

    /// Message for an action that failed where the user expected it to work. A failed copy leaves
    /// the panel open, so it needs somewhere to say why instead of only reaching the log.
    private(set) var actionErrorMessage: String?
    @ObservationIgnored private var actionErrorClearTask: Task<Void, Never>?
    static let actionErrorVisibleSeconds: Double = 4

    /// The row removed by the last delete while its backend delete is still deferred. The footer
    /// offers Undo and ⌘Z restores the row only while this is set.
    private(set) var undoableDeletionID: UUID?
    @ObservationIgnored private var pendingDeletion: PendingDeletion?
    /// Changes only when the rows are replaced by another query or cleared; `searchVersion` also
    /// advances for in-flight work invalidated by a deletion event, which keeps the same rows.
    @ObservationIgnored private var projectionIdentity = UUID()
    @ObservationIgnored private var quickSlotHintsVisible = false

    /// Why the last search, history load or page fetch failed. The rows on screen are kept; the
    /// footer shows this with a retry until the next search or load starts.
    private(set) var fetchFailureMessage: String?

    static let initialPageSize = 50
    static let loadMorePageSize = 100
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
        _ = projectionGeneration
        return listState.pinnedItems
    }

    var unpinnedItems: [ClipboardItemDTO] {
        _ = projectionGeneration
        return listState.unpinnedItems
    }

    var items: [ClipboardItemDTO] {
        get {
            _ = projectionGeneration
            return listState.items
        }
        set {
            let currentItems = excludingKnownDeletedItems(newValue)
            if isUnfilteredList {
                searchMatchContexts.removeAll(keepingCapacity: true)
            }
            mutateProjection { $0.replaceItems(currentItems) }
            mergeKnownContentRevisions(currentItems)
        }
    }

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
    var isLoading: Bool = false
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

    private var searchVersion: Int = 0

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
        await reconcilePendingDeletion(with: event)
        switch event {
        case .newItem(let item):
            mergeKnownContentRevisions([item], allowRevivingDeletedItems: true)
            if let bundleID = item.appBundleID, !recentApps.contains(bundleID) {
                scheduleRecentAppsRefresh()
            }

            if hasSemanticSearchQuery {
                search()
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
                mutateProjection { $0.incrementTotalCount() }
            } else if isUnfilteredList, totalCount >= 0 {
                mutateProjection { $0.incrementTotalCount() }
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
                mutateProjection { $0.recomputeCanLoadMore() }
            }
        case .itemContentUpdated(let item):
            mergeKnownContentRevisions([item])
            guard !contentRevisionRegistry.isDeleted(itemID: item.id) else { return }
            if hasSemanticSearchQuery {
                search()
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

            let isUnfilteredList = isUnfilteredList
            mutateProjection {
                $0.decrementTotalCountIfNeeded(wasPresent: wasPresent, isUnfilteredList: isUnfilteredList)
            }
            if hasActiveFilters {
                search()
            }
        case .itemsRemoved(let itemIDs):
            let deletedIDs = Set(itemIDs)
            guard !deletedIDs.isEmpty else { return }
            let newlyDeletedCount = invalidateKnownContentRevisions(itemIDs: deletedIDs)
            invalidateInFlightProjectionWorkForDeletion()
            mutateProjection { _ = $0.removeItems(withIDs: deletedIDs) }
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
                    mutateProjection { $0.updateTotalCount(stats.itemCount) }
                    settingsViewModel.storageStats = stats
                } catch {
                    guard projectionVersion == searchVersion, isUnfilteredList else { return }
                    // Exact committed IDs are still the best available authority on a transient
                    // stats read failure; duplicate bulk events do not decrement twice.
                    mutateProjection { $0.decrementTotalCount(by: newlyDeletedCount) }
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
        fetchFailureMessage = nil
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
                let revisionBeforeFetch = projectionGeneration
                let pinnedItems = try await service.fetchPinned()
                let recentItems = try await service.fetchRecentUnpinned(
                    limit: Self.initialPageSize,
                    offset: 0
                )
                guard shouldApplyLoadResult(version: currentVersion) else { return }
                guard projectionGeneration == revisionBeforeFetch else { continue }
                fetchedItems = excludingKnownDeletedItems(pinnedItems + recentItems)
                hasStableSnapshot = true
                break
            }
            guard shouldApplyLoadResult(version: currentVersion) else { return }
            guard hasStableSnapshot else {
                scheduleLoadAfterStaleSnapshot(version: currentVersion)
                return
            }

            searchMatchContexts.removeAll(keepingCapacity: true)
            mutateProjection { $0.replaceItems(fetchedItems) }
            mergeKnownContentRevisions(fetchedItems)
            prewarmDisplayText(for: fetchedItems)
            searchCoverage = .complete
            lastLoadedAt = Date()

            // Load latency should reflect "first screen ready" rather than unrelated background work.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            Task { await PerformanceMetrics.shared.recordLoadLatency(elapsedMs) }

            let stats = try await service.getStorageStats()
            guard shouldApplyLoadResult(version: currentVersion) else { return }

            mutateProjection { $0.updateTotalCount(stats.itemCount) }

            settingsViewModel.storageStats = stats
            scheduleStorageDetailsRefresh(version: currentVersion)
        } catch {
            guard shouldApplyLoadResult(version: currentVersion) else { return }
            reportFetchFailure(String(localized: "Loading history failed"), error)
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

    /// Rows before the end of the loaded page start the next fetch, so the page is usually applied
    /// before the user reaches the end trigger.
    static let loadMorePrefetchRows = 40

    func rowDidAppear(itemID: UUID) {
        guard canLoadMore, !isLoading, loadMoreTask == nil else { return }
        guard let index = indexOfItem(withID: itemID), index >= loadedCount - Self.loadMorePrefetchRows else { return }
        Task { await loadMore() }
    }

    /// Rows applied per chunk; chunks are 20 ms apart so a 100-row page costs five small List
    /// updates instead of one long one while the user is still scrolling.
    static let loadMoreApplyChunkRows = 20

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
            // After a failure the rows may not belong to the current request; paging waits for a retry.
            guard canLoadMore, !isLoading, fetchFailureMessage == nil else { return }

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
                        cancelTask(&refineTask)
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
                    let result = try await service.search(query: request)
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    prewarmDisplayText(for: acceptedSearchHits(result.hits).map(\.item))
                    guard await appendSearchPage(with: result, version: currentVersion) else { return }
                    searchCoverage = result.coverage
                } else {
                    ScrollPerformanceProfile.shared.incrementCounter(
                        name: "list.pagination_request"
                    )
                    let moreItems = try await service.fetchRecentUnpinned(
                        limit: Self.loadMorePageSize,
                        offset: pagingOffset(unpinnedItems.count, countsPinned: false)
                    )
                    guard !Task.isCancelled, currentVersion == searchVersion else { return }
                    let currentItems = excludingKnownDeletedItems(moreItems)
                    prewarmDisplayText(for: currentItems)
                    var start = 0
                    while start < currentItems.count {
                        let chunk = Array(currentItems[start..<min(currentItems.count, start + Self.loadMoreApplyChunkRows)])
                        mutateProjection { $0.appendRecentPage(items: chunk) }
                        mergeKnownContentRevisions(chunk)
                        start += chunk.count
                        if start < currentItems.count {
                            // Yield so the UI can commit this chunk before receiving more rows.
                            try? await Task.sleep(nanoseconds: 20_000_000)
                            guard !Task.isCancelled, currentVersion == searchVersion else { return }
                        }
                    }
                    searchCoverage = .complete
                }
            } catch {
                guard !Task.isCancelled, currentVersion == searchVersion else { return }
                if searchCoverage.isStagedRefine {
                    searchCoverage = .incomplete
                }
                reportFetchFailure(String(localized: "Loading more failed"), error)
                ScopyLog.app.error("Failed to load more: \(error.localizedDescription, privacy: .private)")
            }
        }

        loadMoreTask = task
        await task.value
    }

    // MARK: - Search

    /// The current rows stay on screen until the versioned replacement arrives: clearing them per
    /// keystroke emptied the List and rebuilt it twice more when the results landed. A failed search
    /// also keeps them, marks coverage incomplete and reports the failure in the footer, so a
    /// failure never reads as "No results". A valid candidate without renderable evidence is not a
    /// failed search and keeps the row with its ordinary metadata.
    func search() {
        cancelTask(&searchTask)
        cancelTask(&refineTask)
        cancelTask(&staleLoadRetryTask)
        cancelTask(&storageDetailsTask)
        fetchFailureMessage = nil

        searchVersion += 1
        projectionIdentity = UUID()
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

        // Own the loading state across the debounce.
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
                let prefilterItems = acceptedSearchHits(result.hits).map(\.item)
                prewarmDisplayText(for: prefilterItems)
                let refineFollows = (searchMode == .fuzzy || searchMode == .fuzzyPlus)
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
                    let refineQuery = searchQuery
                    let refineMode = searchMode
                    let refineAppFilter = appFilter
                    let refineTypeFilter = typeFilter
                    let refineTypeFilters = typeFilters
                    let refineVersion = currentVersion

                    let refine = Task {
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

                            prewarmDisplayText(for: acceptedSearchHits(refined.hits).map(\.item))
                            replaceSearchPage(with: refined, skippingIdenticalRefine: true)
                            searchCoverage = refined.coverage
                        } catch {
                            guard !Task.isCancelled, refineVersion == searchVersion else { return }
                            if let deferredEmptyPage {
                                replaceSearchPage(with: deferredEmptyPage)
                            } else if !searchCoverage.isStagedRefine {
                                return
                            }
                            searchCoverage = .incomplete
                            ScopyLog.app.warning("Refine search failed: \(error.localizedDescription, privacy: .private)")
                        }
                    }
                    refineTask = refine
                    if deferredEmptyPage != nil { pendingRefine = refine }
                }

                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                Task { await PerformanceMetrics.shared.recordSearchLatency(elapsedMs) }
                // With the prefilter page deferred, loading lasts until the refine lands: the empty
                // state shows only for a final empty result, and the previous query's rows on
                // screen cannot start paging for this one.
                await pendingRefine?.value
            } catch {
                guard !Task.isCancelled, currentVersion == searchVersion else { return }
                searchCoverage = .incomplete
                reportFetchFailure(String(localized: "Search failed"), error)
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
            reportActionFailure(error)
        }
    }

    /// Removes the row at once and sends the backend delete after `Timing.undoDeletionWindowNs`,
    /// so the footer or ⌘Z can undo it. One deletion is pending at a time: the next delete, a
    /// clear, or closing the panel commits the previous one first. The tombstone keeps events,
    /// searches and loads from reviving the row meanwhile, and closes its pinned preview.
    func delete(_ item: ClipboardItemDTO) async {
        // Take the undo slot over before any await: a delete that starts while the previous one
        // is being sent must not be overwritten when this call resumes.
        let previous = pendingDeletion
        previous?.commit.cancel()
        pendingDeletion = nil
        invalidateKnownContentRevision(itemID: item.id)
        let index = indexOfItem(withID: item.id) ?? 0
        let predecessorID = index > 0 ? listState.item(at: index - 1)?.id : nil
        let successorID = listState.item(at: index + 1)?.id
        let evidence = searchMatchContexts[item.id]
        _ = removeItem(withID: item.id)
        let token = UUID()
        let window = timing.undoDeletionWindowNs
        pendingDeletion = PendingDeletion(
            item: item,
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
        undoableDeletionID = item.id
        if let previous { await sendDeletion(previous) }
    }

    func undoPendingDeletion() async {
        guard let pending = pendingDeletion else { return }
        pending.commit.cancel()
        pendingDeletion = nil
        undoableDeletionID = nil
        revive(pending)
    }

    /// Sends the pending backend delete now instead of at the end of the undo window.
    func commitPendingDeletionNow() async {
        guard let pending = pendingDeletion else { return }
        pending.commit.cancel()
        pendingDeletion = nil
        undoableDeletionID = nil
        await sendDeletion(pending)
    }

    private func commitPendingDeletion(token: UUID) async {
        guard let pending = pendingDeletion, pending.token == token else { return }
        pendingDeletion = nil
        undoableDeletionID = nil
        await sendDeletion(pending)
    }

    /// The backend delete of a row whose undo window is over; the slot has already moved on, so a
    /// newer pending deletion is never touched here.
    private func sendDeletion(_ pending: PendingDeletion) async {
        do {
            try await service.delete(itemID: pending.item.id)
        } catch {
            ScopyLog.app.error("Delete failed: \(error.localizedDescription, privacy: .private)")
            revive(pending)
            reportActionFailure(error)
        }
    }

    /// The backend deleted the pending row itself; there is nothing left to send or undo.
    private func discardPendingDeletion() {
        pendingDeletion?.commit.cancel()
        pendingDeletion = nil
        undoableDeletionID = nil
    }

    /// A pending deletion is undone implicitly when the backend publishes the same row again
    /// (identical content copied inside the window and deduplicated onto this row): committing
    /// it would delete what the user just copied.
    private func reconcilePendingDeletion(with event: ClipboardEvent) async {
        guard let pending = pendingDeletion else { return }
        switch event {
        case .newItem(let item), .itemUpdated(let item), .itemContentUpdated(let item):
            if item.id == pending.item.id { await undoPendingDeletion() }
        case .itemDeleted(let id):
            if id == pending.item.id { discardPendingDeletion() }
        case .itemsRemoved(let ids):
            if ids.contains(pending.item.id) { discardPendingDeletion() }
        case .itemsCleared(let keepPinned):
            if !(keepPinned && pending.item.isPinned) { discardPendingDeletion() }
        default:
            break
        }
    }

    /// Lifts the tombstone and puts the row back where it was removed from, with its evidence,
    /// while the projection is still the one it left; after a new search or load the row simply
    /// shows up in the next fetch.
    private func revive(_ pending: PendingDeletion) {
        mergeKnownContentRevisions([pending.item], allowRevivingDeletedItems: true)
        guard pending.projection == projectionIdentity else { return }
        let index: Int
        if let successorID = pending.successorID, let successor = indexOfItem(withID: successorID) {
            index = successor
        } else if let predecessorID = pending.predecessorID, let predecessor = indexOfItem(withID: predecessorID) {
            index = predecessor + 1
        } else {
            index = pending.index
        }
        mutateProjection { $0.insertItem(pending.item, at: index) }
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
        projectionIdentity = UUID()
        isLoading = false
        selectedID = nil
        lastSelectionSource = .programmatic
        let preservedItems = isUnfilteredList ? pinnedSurvivors.items : []
        searchMatchContexts.removeAll(keepingCapacity: true)
        mutateProjection {
            $0.replacePage(items: preservedItems, total: preservedItems.count, hasMore: false)
        }
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

    private func acceptedSearchHits(_ hits: [SearchResultHit]) -> [SearchResultHit] {
        hits.filter { contentRevisionRegistry.acceptsProjection(itemID: $0.item.id) }
    }

    private func replaceSearchPage(with result: SearchResultPage, skippingIdenticalRefine: Bool = false) {
        let hits = acceptedSearchHits(result.hits)
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
            mutateProjection { $0.updatePagination(total: result.total, hasMore: result.hasMore) }
            return
        }
        // Evidence first: rows created for the new page read theirs when they are built.
        searchMatchContexts = contexts
        mutateProjection {
            $0.replacePage(items: resultItems, total: result.total, hasMore: result.hasMore)
        }
        mergeKnownContentRevisions(resultItems)
        reconcileSelectionAfterProjectionReplacement()
    }

    private func applyRefinedSearchPage(with result: SearchResultPage, version: Int) async -> Bool {
        let hits = acceptedSearchHits(result.hits)
        let existingIDs = Set(items.map(\.id))
        let newHits = hits.filter { !existingIDs.contains($0.item.id) }
        prewarmDisplayText(for: hits.map(\.item))
        // Keep the staged rows, including the visible scroll anchor and selection, present
        // while mounting new rows. Once they exist, commit the full ranking atomically.
        // Replacing a truncated prefix first can temporarily remove the current scroll anchor.
        if !newHits.isEmpty {
            let additions = SearchResultPage(
                hits: newHits,
                total: result.total,
                hasMore: result.hasMore,
                coverage: result.coverage
            )
            guard await appendSearchPage(with: additions, version: version) else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !Task.isCancelled, version == searchVersion else { return false }
        replaceSearchPage(with: result, skippingIdenticalRefine: true)
        return true
    }

    private func appendSearchPage(with result: SearchResultPage, version: Int) async -> Bool {
        guard !Task.isCancelled, version == searchVersion else { return false }
        if result.hits.isEmpty {
            mutateProjection { $0.updatePagination(total: result.total, hasMore: result.hasMore) }
            return true
        }
        var start = 0
        while start < result.hits.count {
            guard !Task.isCancelled, version == searchVersion else { return false }
            let end = min(start + Self.loadMoreApplyChunkRows, result.hits.count)
            let hits = acceptedSearchHits(Array(result.hits[start..<end]))
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
                    hasMore: end < result.hits.count || result.hasMore
                )
            }
            mergeKnownContentRevisions(resultItems)
            start = end
            if start < result.hits.count {
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
    private func setItemIfChanged(at index: Int, to value: ClipboardItemDTO) -> Bool {
        var changed = false
        mutateProjection { changed = $0.setItemIfChanged(at: index, to: value) }
        return changed
    }

    @discardableResult
    private func removeItem(withID id: UUID) -> Bool {
        searchMatchContexts.removeValue(forKey: id)
        if selectedID == id {
            selectedID = nil
            lastSelectionSource = .programmatic
        }
        var removed = false
        mutateProjection { removed = $0.removeItem(withID: id) }
        return removed
    }

    @discardableResult
    private func insertOrMoveItemToFront(_ item: ClipboardItemDTO) -> Bool {
        var changed = false
        mutateProjection { changed = $0.insertOrMoveItemToFront(item) }
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
        projectionWillChange?()
        change(&listState)
        if projectionGeneration != listState.projectionGeneration {
            projectionGeneration = listState.projectionGeneration
            if quickSlotHintsVisible { fanOutQuickSlots() }
            projectionDidChange?()
        }
        if totalCount != listState.totalCount { totalCount = listState.totalCount }
        if canLoadMore != listState.canLoadMore { canLoadMore = listState.canLoadMore }
    }

    private func cancelTask(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}
