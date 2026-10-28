import AppKit
import Foundation
import SwiftUI
import ScopyKit
import ScopyUISupport

/// Hover preview popover kind used to coordinate a single active preview across the list.
enum HoverPreviewPopoverKind: Equatable {
    case image
    case text
    case file
}

/// The currently active hover preview popover (at most one at a time).
struct HoverPreviewPopoverState: Equatable {
    let itemID: UUID
    let kind: HoverPreviewPopoverKind
}

/// The history list: pinned rows, recent rows and automatic paging.
@MainActor
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel

    let openSettings: (() -> Void)?

    // One hover WebView for the whole list. With the `@State` property wrapper (Xcode 16, CI) a
    // default value is evaluated on every `HistoryListView` init, which built and discarded a
    // WKWebView each time; Xcode 27's `@State` macro defers it, older toolchains do not.
    // `@StateObject` evaluates its autoclosure once per list on every toolchain.
    @StateObject private var sharedMarkdownPreview = SharedMarkdownPreviewSlot()
    @State private var interactionCoordinator = HistoryListInteractionCoordinator()
    @State private var interactionSessionStore = HistoryItemInteractionSessionStore()
    @State private var relativeTimeClock = HistoryRelativeTimeClock()

    // Enforce that at most one hover preview popover is presented at a time.
    @State private var pinnedPreviewController = PinnedPreviewController()
    @State private var presentation = HoverPreviewPresentation()
    @State private var programmaticScrollGate = ListProgrammaticScrollGate()

    /// The section header rows, the list's top for `HistoryViewModel.scrollListToTop`.
    private static let pinnedHeaderID = "History.PinnedHeader"
    private static let recentHeaderID = "History.RecentHeader"

    private static let isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("--uitesting")
    private static let isScrollProfile: Bool = ProcessInfo.processInfo.environment["SCOPY_SCROLL_PROFILE"] == "1"
    private static let profileAccessibility: Bool = ProcessInfo.processInfo.environment["SCOPY_PROFILE_ACCESSIBILITY"] == "1"
    private static let shouldExposeAccessibility: Bool = isScrollProfile ? profileAccessibility : isUITesting

    var body: some View {
        // List (NSTableView underneath) recycles row views; a ScrollView + LazyVStack kept every
        // row it had shown alive (~500 MB for 10k items against ~50 MB).
        // The List stays mounted when a search has no rows; the empty and loading states are a
        // leaf overlay, so this body never reads `isLoading` or the filter state.
        ScrollViewReader { proxy in
            let _ = ScrollPerformanceProfile.incrementCounter(name: "list.body")
            List {
                // Read each observed collection once so the body registers one dependency per property.
                let pinned = historyViewModel.pinnedItems
                let unpinned = historyViewModel.unpinnedItems
                // Rows are built inside ForEach child closures, where every @Observable read installs its own
                // observation and copies the access list; read the shared state once here and pass values down.
                let rowContext = HistoryRowContext(
                    settings: settingsViewModel.settings,
                    markdownWebViewController: sharedMarkdownPreview.controller
                )

                // Section titles are ordinary rows: a List Section header draws an opaque background.
                // Pinned Section Header
                if !pinned.isEmpty {
                    SectionHeader(
                        title: String(localized: "Pinned"),
                        count: pinned.count,
                                        isCollapsible: true,
                        isCollapsed: historyViewModel.isPinnedCollapsed,
                        onToggle: { historyViewModel.isPinnedCollapsed.toggle() }
                    )
                    .id(Self.pinnedHeaderID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    // Pinned Items
                    if !historyViewModel.isPinnedCollapsed {
                        ForEach(pinned) { item in
                            historyRow(item: item, context: rowContext)
                        }
                    }
                }

                // Recent Section Header (hidden while the empty overlay stands in for the list)
                if !pinned.isEmpty || !unpinned.isEmpty {
                    RecentSectionHeader(count: unpinned.count)
                    .id(Self.recentHeaderID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                // Recent Items
                ForEach(unpinned) { item in
                    historyRow(item: item, context: rowContext)
                }

                // Load More Trigger
                if historyViewModel.canLoadMore {
                    LoadMoreTriggerView()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .onAppear {
                            Task { await historyViewModel.loadMore() }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .accessibilityIdentifier("History.List")
            .background(
                ListLiveScrollObserverView(
                    interactionCoordinator: interactionCoordinator,
                    onScrollStart: {
                        interactionCoordinator.beginScrolling()
                        relativeTimeClock.scrollDidStart()
                        historyViewModel.scrollDidStart()
                        if HistoryListUITestRuntime.isEnabled {
                            HistoryListUITestProbe.shared.recordProductionScrollStart()
                        }
                    },
                    onScrollEnd: {
                        interactionCoordinator.endScrolling()
                        relativeTimeClock.scrollDidEnd()
                        historyViewModel.scrollDidEnd()
                        if HistoryListUITestRuntime.isEnabled {
                            HistoryListUITestProbe.shared.recordProductionScrollEnd()
                        }
                    },
                    onScrollViewAttach: scrollViewAttachHandler,
                    programmaticScrollGate: programmaticScrollGate
                )
            )
            .background(ScrollFrameSamplerView())
            .onAppear {
                // Selection reaches rows through the fan-out, never through this body; the
                // List is diffed only when its items change. Keyboard navigation follows here.
                historyViewModel.rowLiveState.onSelectionChanged = { id, follow in
                    guard follow, let id else { return }
                    programmaticScrollGate.beginProgrammaticScroll()
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                historyViewModel.scrollListToTop = {
                    programmaticScrollGate.beginProgrammaticScroll()
                    proxy.scrollTo(
                        historyViewModel.pinnedItems.isEmpty ? Self.recentHeaderID : Self.pinnedHeaderID,
                        anchor: .top
                    )
                }
            }
            .onDisappear {
                historyViewModel.rowLiveState.onSelectionChanged = nil
                historyViewModel.scrollListToTop = nil
            }
        }
        .overlay { HistoryListEmptyOverlay(openSettings: openSettings) }
        .environment(\.historyRelativeTimeClock, relativeTimeClock)
        .background(
            HistoryWindowVisibilityObserver(clock: relativeTimeClock)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .onAppear {
            // The fixed driver scrolls NSClipView directly, so AppKit does not publish the live-
            // scroll notifications that normally pause this clock. Freeze its launch bucket for
            // the controlled workload to keep a 30-second boundary out of the measurement window.
            relativeTimeClock.start(
                pausedForScrolling: ScrollPerformanceProfile.shared.usesFixedDriverAnimationSampler
            )
            historyViewModel.retainedContentItemIDs = { [weak interactionSessionStore, weak pinnedPreviewController] in
                (interactionSessionStore?.retainedItemIDs ?? [])
                    .union(pinnedPreviewController?.retainedItemIDs ?? [])
            }
            reconcileRetainedPreviewState()
            updateProfileWorkloadMetadata()
        }
        .background(
            // Observed from a leaf view: an `onChange(of:)` here would make this body, and with it
            // every row, depend on `isLoading` and the other per-search flags.
            HistoryListStateObservers(
                onWorkloadChange: updateProfileWorkloadMetadata,
                onItemsRevisionChange: recordHistoryListIntegrationModelNoteIfNeeded,
                onContentRevisionReconciliation: reconcileRetainedPreviewState
            )
        )
        .onDisappear {
            relativeTimeClock.stop()
            interactionCoordinator.tearDownPassivePath()
        }
        .task {
            await historyViewModel.applyScrollProfileSearchIfNeeded()
            updateProfileWorkloadMetadata()
        }
        .overlay(alignment: .topLeading) {
            if HistoryListUITestRuntime.isEnabled {
                HistoryListUITestProbeAccessibilityView(
                    probe: HistoryListUITestProbe.shared
                )
            }
        }
    }

    // MARK: - Preview Popover Coordination

    /// The presented popover lives in the row fan-out, so changing it re-renders the two rows
    /// involved instead of this body.
    private var activePopover: HoverPreviewPopoverState? {
        get { historyViewModel.rowLiveState.presentedPreview }
        nonmutating set { historyViewModel.rowLiveState.updatePresentedPreview(newValue) }
    }

    private var pendingPopover: HoverPreviewPopoverState? {
        get { presentation.pending }
        nonmutating set { presentation.pending = newValue }
    }

    private func updateProfileWorkloadMetadata() {
        guard ScrollPerformanceProfile.isEnabled else { return }
        let profile = ScrollPerformanceProfile.shared
        let environment = ProcessInfo.processInfo.environment
        let expectedSearchQuery = environment["SCOPY_PROFILE_SEARCH_QUERY"] ?? ""
        let expectedSearchMode = environment["SCOPY_PROFILE_SEARCH_MODE"] ?? ""
        let isSearchProfile = !expectedSearchQuery.isEmpty
        let searchReady = isSearchProfile
            && historyViewModel.searchQuery == expectedSearchQuery
            && historyViewModel.searchMode.rawValue == expectedSearchMode
            && !historyViewModel.isLoading
            && !historyViewModel.items.isEmpty
            && historyViewModel.searchMatchContexts.count == historyViewModel.items.count
            && historyViewModel.items.allSatisfy {
                historyViewModel.searchMatchContext(for: $0.id) != nil
            }
        let datasetMetadata: ScrollProfileDatasetMetadata? = {
            guard profile.usesFixedDriverAnimationSampler,
                  let datasetID = environment["SCOPY_MOCK_DATASET_ID"]?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ),
                  !datasetID.isEmpty
            else { return nil }

            let orderedItems = historyViewModel.pinnedItems + historyViewModel.unpinnedItems
            let metadata = HistoryProfileDatasetFingerprint.make(
                datasetID: datasetID,
                items: orderedItems
            )
            return ScrollProfileDatasetMetadata(
                schema: metadata.schema,
                datasetID: metadata.datasetID,
                fingerprint: metadata.fingerprint,
                itemCount: metadata.itemCount,
                textItemCount: metadata.textItemCount,
                imageItemCount: metadata.imageItemCount,
                pinnedItemCount: metadata.pinnedItemCount,
                uniqueItemIDCount: metadata.uniqueItemIDCount,
                minimumTextUTF8Bytes: metadata.minimumTextUTF8Bytes,
                maximumTextUTF8Bytes: metadata.maximumTextUTF8Bytes
            )
        }()
        profile.setListWorkloadMetadata(
            loadedCount: historyViewModel.loadedCount,
            totalCount: historyViewModel.totalCount,
            canLoadMore: historyViewModel.canLoadMore,
            searchEvidenceCount: historyViewModel.searchMatchContexts.count,
            searchQuery: isSearchProfile ? historyViewModel.searchQuery : "",
            searchMode: isSearchProfile ? historyViewModel.searchMode.rawValue : "",
            searchReady: searchReady,
            dataset: datasetMetadata
        )
        if searchReady {
            profile.beginAutoScrollAfterReadiness()
        }
        let snapshot = interactionCoordinator.passivePathSnapshot
        profile.recordPassivePathSnapshot(
            activeSlotCount: snapshot.activeRowCount,
            suppressedCandidateCount: snapshot.suppressedHoverCandidateCount
        )
    }

    private var scrollViewAttachHandler: ((NSScrollView) -> Void)? {
        guard ScrollPerformanceProfile.isEnabled || HistoryListUITestRuntime.isEnabled else {
            return nil
        }
        return { scrollView in
            if ScrollPerformanceProfile.isEnabled {
                ScrollPerformanceProfile.shared.attachScrollView(scrollView)
            }
            if HistoryListUITestRuntime.isEnabled {
                HistoryListUITestProbe.shared.attach(scrollView: scrollView)
            }
        }
    }

    private func recordHistoryListIntegrationModelNoteIfNeeded() {
        guard HistoryListUITestRuntime.isEnabled,
              let note = historyViewModel.items.first(where: {
                  $0.id == HistoryListUITestRuntime.fileTargetID
              })?.note else { return }
        HistoryListUITestProbe.shared.recordModelPersistedNote(note)
    }

    /// Both off-list holders of preview state apply the same snapshot: a retained row session and
    /// the pinned window must not disagree about whether an item is still there.
    @MainActor
    private func reconcileRetainedPreviewState() {
        let snapshot = historyViewModel.contentRevisionReconciliationSnapshot
        interactionSessionStore.reconcile(snapshot: snapshot)
        pinnedPreviewController.reconcile(snapshot: snapshot)
    }

    @MainActor
    private func detachSharedMarkdownWebViewIfAttached() {
        guard sharedMarkdownPreview.controller.webView.superview != nil else { return }
        sharedMarkdownPreview.controller.detachWebView()
        sharedMarkdownPreview.controller.webView.removeFromSuperview()
    }

    @MainActor
    private func dismissAnyPopover(except itemID: UUID) {
        if activePopover?.itemID == itemID {
            return
        }

        // AppKit normally delivers the source row's exit before the adjacent row's enter, but
        // defer one turn so the source can claim hover-transfer ownership even if that ordering
        // flips at a window/screen edge.
        let expectedActive = activePopover
        let expectedPending = pendingPopover
        DispatchQueue.main.async {
            guard activePopover == expectedActive, pendingPopover == expectedPending else { return }
            if let existing = activePopover,
               interactionCoordinator.hoverPreviewTransferOwnerID == existing.itemID {
                return
            }
            if let existing = activePopover {
                recordPopoverDismiss(itemID: existing.itemID)
            }
            pendingPopover = nil
            activePopover = nil
            detachSharedMarkdownWebViewIfAttached()
        }
    }

    @MainActor
    private func recordPopoverDismiss(itemID: UUID) {
        presentation.recordDismiss(itemID: itemID)
    }

    @MainActor
    private func schedulePopoverPresentation(_ next: HoverPreviewPopoverState, delaySeconds: CFTimeInterval) {
        pendingPopover = next
        if delaySeconds <= 0 {
            DispatchQueue.main.async {
                guard pendingPopover == next else { return }
                activePopover = next
                pendingPopover = nil
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            guard pendingPopover == next else { return }
            activePopover = next
            pendingPopover = nil
        }
    }

    @MainActor
    private func reopenDelaySeconds(for itemID: UUID) -> CFTimeInterval {
        presentation.reopenDelaySeconds(for: itemID)
    }

    /// Transfer only the current hover WebView. Other windows and the next hover have
    /// independent ownership, so delayed dismantling cannot steal another window's content.
    @MainActor
    private func pinPreview(
        item: ClipboardItemDTO,
        kind: HoverPreviewPopoverKind,
        model: HoverPreviewModel,
        revision: ClipboardItemContentRevision
    ) {
        if pinnedPreviewController.isPinned(itemID: item.id) {
            detachSharedMarkdownWebViewIfAttached()
            pendingPopover = nil
            activePopover = nil
            historyViewModel.closePanelHandler?()
            pinnedPreviewController.focus(itemID: item.id)
            return
        }
        let filePreview = kind == .file
            ? FilePreviewSupport.previewSummary(from: item.plainText, requireExists: true) : nil
        let controller = model.isMarkdown ? sharedMarkdownPreview.controller : nil
        guard let preview = PinnedPreview(
            item: item,
            revision: revision,
            kind: kind,
            filePreviewKind: filePreview?.kind,
            filePreviewPath: filePreview?.path,
            source: model,
            markdownWebViewController: controller
        ) else { return }
        detachSharedMarkdownWebViewIfAttached()
        if controller != nil { sharedMarkdownPreview.controller = MarkdownPreviewWebViewController() }
        pendingPopover = nil
        activePopover = nil
        pinnedPreviewController.pin(preview, settingsViewModel: settingsViewModel) {
            historyViewModel.closePanelHandler?()
        }
    }

    @MainActor
    private func presentPopover(itemID: UUID, kind: HoverPreviewPopoverKind) {
        let next = HoverPreviewPopoverState(itemID: itemID, kind: kind)
        if let existing = activePopover,
           existing.itemID != itemID,
           interactionCoordinator.hoverPreviewTransferOwnerID == existing.itemID {
            return
        }
        if activePopover == next {
            // SwiftUI's popover binding can occasionally get out-of-sync on macOS (popover dismissed by the system
            // without driving the `isPresented` binding back to `false`). In that case, re-hovering the same row
            // would be blocked by this equality check. Force a toggle to allow re-presenting the same popover.
            recordPopoverDismiss(itemID: itemID)
            detachSharedMarkdownWebViewIfAttached()
            activePopover = nil
            schedulePopoverPresentation(next, delaySeconds: reopenDelaySeconds(for: itemID))
            return
        }

        if activePopover != nil {
            // Close current popover first, then present the next one on the next run loop tick.
            // This avoids attempting to attach the same WKWebView to two view hierarchies in one update cycle.
            if let existing = activePopover {
                recordPopoverDismiss(itemID: existing.itemID)
            }
            detachSharedMarkdownWebViewIfAttached()
            activePopover = nil
            schedulePopoverPresentation(next, delaySeconds: reopenDelaySeconds(for: itemID))
            return
        }

        // If the shared web view is still attached (e.g. pre-measure view), detach it before presenting the popover.
        // Present on the next run loop tick to avoid transient "already has a superview" issues.
        if sharedMarkdownPreview.controller.webView.superview != nil {
            detachSharedMarkdownWebViewIfAttached()
            schedulePopoverPresentation(next, delaySeconds: reopenDelaySeconds(for: itemID))
            return
        }

        pendingPopover = nil
        let delay = reopenDelaySeconds(for: itemID)
        if delay > 0 {
            schedulePopoverPresentation(next, delaySeconds: delay)
            return
        }
        activePopover = next
    }

    @MainActor
    private func dismissPopoverIfActive(itemID: UUID) {
        if pendingPopover?.itemID == itemID {
            pendingPopover = nil
        }
        if activePopover?.itemID == itemID {
            recordPopoverDismiss(itemID: itemID)
            detachSharedMarkdownWebViewIfAttached()
            activePopover = nil
        }
    }

    /// The List reads each row's identity and row modifiers from the ForEach child without building
    /// the row, so they go outside `.equatable()`: inside it the List never sees them.
    private func historyRow(item: ClipboardItemDTO, context: HistoryRowContext) -> some View {
        HistoryLiveRow(item: item, context: context, fanout: historyViewModel.rowLiveState) { item, context, live in
            historyRowContent(item: item, context: context, live: live)
        }
        .equatable()
        // Keep this explicit identity. ForEach already identifies the child by `item.id`, but
        // without `.id` the List's NSTableView loses its measured row heights on every update
        // and re-tiles from the estimate, which moves the content under the viewport when a page
        // lands or a fast scroll ends. Removing it (456abdf) was bisected on device as the cause
        // of the scroll-stop jump on 2026-09-25.
        .id(item.id)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func historyRowContent(
        item: ClipboardItemDTO,
        context: HistoryRowContext,
        live: HistoryRowLiveState
    ) -> some View {
        let isSelected = live.isSelected
        let isImagePreviewPresented = live.presentedPreview == .image
        let isTextPreviewPresented = live.presentedPreview == .text
        let isFilePreviewPresented = live.presentedPreview == .file
        let row = HistoryItemView(
            item: item,
            isSelected: isSelected,
            quickSlot: live.quickSlot,
            settings: context.settings,
            searchMatchContext: live.evidence,
            onSelect: { Task { await historyViewModel.select(item) } },
            onSelectOptimizedForCodex: { Task { await historyViewModel.selectOptimizedForCodex(item) } },
            onSendViaAirDrop: { Task { await historyViewModel.sendViaAirDrop(item) } },
            onOpenContainingFolder: { Task { await historyViewModel.openContainingFolder(item) } },
            onHoverSelect: { id in historyViewModel.acceptHoverSelection(id) },
            onTogglePin: { Task { await historyViewModel.togglePin(item) } },
            onDelete: { Task { await historyViewModel.delete(item) } },
            onUpdateNote: { note in
                await historyViewModel.updateNote(item, note: note)
            },
            onOptimizeImage: { await historyViewModel.optimizeImage(item) },
            getImageData: { try? await historyViewModel.getImageData(itemID: item.id) },
            markdownWebViewController: context.markdownWebViewController,
            interactionCoordinator: interactionCoordinator,
            interactionSessionStore: interactionSessionStore,
            isContentRevisionCurrent: { itemID, revision in
                historyViewModel.isContentRevisionCurrent(itemID: itemID, revision: revision)
            },
            isImagePreviewPresented: isImagePreviewPresented,
            isTextPreviewPresented: isTextPreviewPresented,
            isFilePreviewPresented: isFilePreviewPresented,
            requestPopover: { kind in
                guard let kind else {
                    dismissPopoverIfActive(itemID: item.id)
                    return
                }
                presentPopover(itemID: item.id, kind: kind)
            },
            requestPinPreview: { kind, model, revision in
                pinPreview(item: item, kind: kind, model: model, revision: revision)
            },
            dismissOtherPopovers: {
                dismissAnyPopover(except: item.id)
            }
        )
        .equatable()

        if Self.isScrollProfile && !Self.profileAccessibility {
            row.accessibilityHidden(true)
        } else if Self.shouldExposeAccessibility {
            row.accessibilityIdentifier("History.Item.\(item.id.uuidString)")
                .accessibilityValue(isSelected ? "selected" : "unselected")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            row.accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// Holds the list's hover Markdown controller. Pinning a Markdown preview hands the current
/// controller (and its WebView) to the pinned window and installs a fresh one here; publishing
/// the replacement rebuilds the rows with it.
@MainActor
private final class SharedMarkdownPreviewSlot: ObservableObject {
    @Published var controller = MarkdownPreviewWebViewController()
}

/// The empty and first-load states over the always-mounted List. Only this leaf observes
/// `isLoading` and `hasActiveFilters`; it renders nothing while there are rows.
private struct HistoryListEmptyOverlay: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let openSettings: (() -> Void)?

    var body: some View {
        if historyViewModel.items.isEmpty {
            if historyViewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, ScopySpacing.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                EmptyStateView(
                    hasFilters: historyViewModel.hasActiveFilters,
                    openSettings: openSettings
                )
            }
        }
    }
}

/// Keeps the high-frequency scroll flag out of `HistoryListView.body`'s Observation dependency
/// set. Only this small header redraws when scrolling starts or ends; row construction remains
/// driven by item/selection/popover changes.
/// Reads `isScrolling` here, not in the List body: it changes per scroll and would otherwise
/// rebuild every row.
private struct RecentSectionHeader: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let count: Int

    var body: some View {
        SectionHeader(
            title: String(localized: "Recent"),
            count: count,
            isScrolling: historyViewModel.isScrolling
        )
    }
}

private struct ScrollFrameSamplerView: View {
    var body: some View {
        if ScrollPerformanceProfile.isEnabled,
           !ScrollPerformanceProfile.shared.usesFixedDriverAnimationSampler {
            TimelineView(.animation) { context in
                Color.clear
                    .onChange(of: context.date) { _, newValue in
                        ScrollPerformanceProfile.shared.recordAnimationCallback(newValue)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Shared list state a row needs, captured once per list update instead of read per row.
private struct HistoryRowContext: Equatable {
    let settings: SettingsDTO
    let markdownWebViewController: MarkdownPreviewWebViewController

    nonisolated static func == (lhs: HistoryRowContext, rhs: HistoryRowContext) -> Bool {
        lhs.settings == rhs.settings && lhs.markdownWebViewController === rhs.markdownWebViewController
    }
}

/// Holds one row's live state (selection, search evidence) as local state fed by
/// `HistoryRowLiveStateFanout`, so a change re-evaluates the rows it concerns instead of the List
/// body (which re-initializes every ForEach child and diffs every loaded id).
///
/// `Equatable` so a List update skips the body of every row whose item and context are unchanged;
/// the content closure is not compared, so it builds the row only from the values it is passed.
private struct HistoryLiveRow<Content: View>: View, Equatable {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let item: ClipboardItemDTO
    let context: HistoryRowContext
    let fanout: HistoryRowLiveStateFanout
    let content: (ClipboardItemDTO, HistoryRowContext, HistoryRowLiveState) -> Content
    @State private var live: HistoryRowLiveState
    @State private var registrationToken: HistoryRowLiveStateFanout.RegistrationToken?

    init(
        item: ClipboardItemDTO,
        context: HistoryRowContext,
        fanout: HistoryRowLiveStateFanout,
        @ViewBuilder content: @escaping (ClipboardItemDTO, HistoryRowContext, HistoryRowLiveState) -> Content
    ) {
        self.item = item
        self.context = context
        self.fanout = fanout
        self.content = content
        _live = State(initialValue: fanout.state(for: item.id))
    }

    nonisolated static func == (lhs: HistoryLiveRow, rhs: HistoryLiveRow) -> Bool {
        lhs.item == rhs.item && lhs.context == rhs.context && lhs.fanout === rhs.fanout
    }

    var body: some View {
        content(item, context, live)
            .onAppear {
                let token: HistoryRowLiveStateFanout.RegistrationToken
                if let registrationToken {
                    token = registrationToken
                } else {
                    token = .init(itemID: item.id)
                    registrationToken = token
                }
                live = fanout.register(token) { state in
                    live = state
                }
                historyViewModel.rowDidAppear(itemID: item.id)
            }
            .onDisappear {
                if let registrationToken {
                    fanout.unregister(registrationToken)
                }
            }
    }
}

/// Hosts the list-level `onChange` observers so their observed properties belong to this leaf's
/// body instead of `HistoryListView.body`.
private struct HistoryListStateObservers: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let onWorkloadChange: () -> Void
    let onItemsRevisionChange: () -> Void
    let onContentRevisionReconciliation: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: historyViewModel.loadedCount) { _, _ in onWorkloadChange() }
            .onChange(of: historyViewModel.totalCount) { _, _ in onWorkloadChange() }
            .onChange(of: historyViewModel.canLoadMore) { _, _ in onWorkloadChange() }
            .onChange(of: historyViewModel.projectionGeneration) { _, _ in
                onWorkloadChange()
                onItemsRevisionChange()
            }
            .onChange(of: historyViewModel.searchMatchContexts.count) { _, _ in onWorkloadChange() }
            .onChange(of: historyViewModel.isLoading) { _, _ in onWorkloadChange() }
            .onChange(of: historyViewModel.contentRevisionReconciliationToken) { _, _ in
                onContentRevisionReconciliation()
            }
    }
}
