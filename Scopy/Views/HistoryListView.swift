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

/// 历史列表视图 - 符合 v0.md 的懒加载设计
@MainActor
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel

    let openSettings: (() -> Void)?

    // Shared Markdown preview controller to avoid repeatedly creating/destroying WebKit views/processes.
    @State private var sharedMarkdownPreviewController = MarkdownPreviewWebViewController()
    @State private var interactionCoordinator = HistoryListInteractionCoordinator()
    @State private var interactionSessionStore = HistoryItemInteractionSessionStore()
    @State private var relativeTimeClock = HistoryRelativeTimeClock()

    // Enforce that at most one hover preview popover is presented at a time.
    @State private var pinnedPreviewController = PinnedPreviewController()
    @State private var presentation = HoverPreviewPresentation()
    @State private var programmaticScrollGate = ListProgrammaticScrollGate()

    private static let isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("--uitesting")
    private static let isScrollProfile: Bool = ProcessInfo.processInfo.environment["SCOPY_SCROLL_PROFILE"] == "1"
    private static let profileAccessibility: Bool = ProcessInfo.processInfo.environment["SCOPY_PROFILE_ACCESSIBILITY"] == "1"
    private static let shouldExposeAccessibility: Bool = isScrollProfile ? profileAccessibility : isUITesting

    var body: some View {
        // v0.18: 使用 List 替代 ScrollView+LazyVStack 实现真正的视图回收
        // List 基于 NSTableView，具有视图回收能力，10k 项目内存从 ~500MB 降至 ~50MB
        // The List stays mounted when a search has no rows; the empty and loading states are a
        // leaf overlay, so this body never reads `isLoading` or the filter state.
        ScrollViewReader { proxy in
            let _ = ScrollPerformanceProfile.incrementCounter(name: "list.body")
            List {
                // v0.21: 使用局部变量缓存计算属性结果，避免多次访问触发 @Observable 追踪
                // 这样 SwiftUI 只追踪一次 pinnedItems/unpinnedItems 访问
                let pinned = historyViewModel.pinnedItems
                let unpinned = historyViewModel.unpinnedItems
                // Rows are built inside ForEach child closures, where every @Observable read installs its own
                // observation and copies the access list; read the shared state once here and pass values down.
                let rowContext = HistoryRowContext(settings: settingsViewModel.settings)

                // v0.18: 不使用 Section header，改为普通行以避免黑色背景
                // Pinned Section Header
                if !pinned.isEmpty {
                    SectionHeader(
                        title: String(localized: "Pinned"),
                        count: pinned.count,
                                        isCollapsible: true,
                        isCollapsed: historyViewModel.isPinnedCollapsed,
                        onToggle: { historyViewModel.isPinnedCollapsed.toggle() }
                    )
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
            // The List's NSTableView lays out rows it has not measured yet at this height (SwiftUI
            // defaults it to 24 pt; a text row is 43 pt) and corrects them after a fast scroll
            // ends, which moved the visible rows. SwiftUI's delegate answers the per-row height
            // estimate from this value, so setting the table's `rowHeight` directly has no effect.
            // Rows shorter than it (the section headers, the load-more row) are raised to it.
            .environment(\.defaultMinListRowHeight, ScopySize.Height.listRowEstimate)
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
            }
            .onDisappear {
                historyViewModel.rowLiveState.onSelectionChanged = nil
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
        guard sharedMarkdownPreviewController.webView.superview != nil else { return }
        sharedMarkdownPreviewController.detachWebView()
        sharedMarkdownPreviewController.webView.removeFromSuperview()
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
        guard model.hasRenderedContent else { return }
        let snapshot = HoverPreviewModel()
        snapshot.adoptRenderedContent(from: model)
        let filePreview = kind == .file
            ? FilePreviewSupport.previewSummary(from: item.plainText, requireExists: true) : nil
        let controller = model.isMarkdown ? sharedMarkdownPreviewController : nil
        detachSharedMarkdownWebViewIfAttached()
        if controller != nil { sharedMarkdownPreviewController = MarkdownPreviewWebViewController() }
        pendingPopover = nil
        activePopover = nil
        DispatchQueue.main.async {
            if pinnedPreviewController.pin(
                item: item, revision: revision, kind: kind,
                filePreviewKind: filePreview?.kind, filePreviewPath: filePreview?.path,
                source: snapshot, settingsViewModel: settingsViewModel,
                markdownWebViewController: controller
            ) {
                historyViewModel.closePanelHandler?()
            }
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
        if sharedMarkdownPreviewController.webView.superview != nil {
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

    /// v0.18: 添加 List 修饰符以保持原有样式
    /// Shared list state a row needs, captured once per list update instead of read per row.
    private struct HistoryRowContext {
        let settings: SettingsDTO
    }

    private func historyRow(item: ClipboardItemDTO, context: HistoryRowContext) -> some View {
        HistoryLiveRow(itemID: item.id, fanout: historyViewModel.rowLiveState) { live in
            historyRowContent(item: item, context: context, live: live)
        }
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
            isKeyboardSelected: isSelected,
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
            markdownWebViewController: sharedMarkdownPreviewController,
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

        Group {
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
        .listRowInsets(EdgeInsets())      // 移除默认内边距
        .listRowBackground(Color.clear)    // 透明背景
        .listRowSeparator(.hidden)         // 隐藏分隔线
    }
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

/// Holds one row's live state (selection, search evidence) as local state fed by
/// `HistoryRowLiveStateFanout`, so a change re-evaluates the rows it concerns instead of the List
/// body (which re-initializes every ForEach child and diffs every loaded id).
private struct HistoryLiveRow<Content: View>: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let itemID: UUID
    let fanout: HistoryRowLiveStateFanout
    let content: (HistoryRowLiveState) -> Content
    @State private var live: HistoryRowLiveState

    init(
        itemID: UUID,
        fanout: HistoryRowLiveStateFanout,
        @ViewBuilder content: @escaping (HistoryRowLiveState) -> Content
    ) {
        self.itemID = itemID
        self.fanout = fanout
        self.content = content
        _live = State(initialValue: fanout.state(for: itemID))
    }

    var body: some View {
        content(live)
            .onAppear {
                live = fanout.register(itemID: itemID) { state in
                    live = state
                }
                historyViewModel.rowDidAppear(itemID: itemID)
            }
            .onDisappear {
                fanout.unregister(itemID: itemID)
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
            .onChange(of: historyViewModel.itemsRevision) { _, _ in
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
