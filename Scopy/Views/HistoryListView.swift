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

private struct HoverPreviewDismissSnapshot: Equatable {
    let itemID: UUID
    let at: CFTimeInterval
}

/// 历史列表视图 - 符合 v0.md 的懒加载设计
@MainActor
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel

    let openSettings: (() -> Void)?

    // Shared Markdown preview controller to avoid repeatedly creating/destroying WebKit views/processes.
    @StateObject private var sharedMarkdownPreviewController = MarkdownPreviewWebViewController()
    @State private var interactionCoordinator = HistoryListInteractionCoordinator()
    @State private var interactionSessionStore = HistoryItemInteractionSessionStore()
    @State private var relativeTimeClock = HistoryRelativeTimeClock()

    // Enforce that at most one hover preview popover is presented at a time.
    @State private var pinnedPreviewController = PinnedPreviewController()
    @State private var activePopover: HoverPreviewPopoverState?
    @State private var pendingPopover: HoverPreviewPopoverState?
    @State private var lastDismissedPopover: HoverPreviewDismissSnapshot?
    @State private var programmaticScrollGate = ListProgrammaticScrollGate()

    private static let popoverReopenCooldownSeconds: CFTimeInterval = 0.25

    private static let isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("--uitesting")
    private static let isScrollProfile: Bool = ProcessInfo.processInfo.environment["SCOPY_SCROLL_PROFILE"] == "1"
    private static let profileAccessibility: Bool = ProcessInfo.processInfo.environment["SCOPY_PROFILE_ACCESSIBILITY"] == "1"
    private static let shouldExposeAccessibility: Bool = isScrollProfile ? profileAccessibility : isUITesting

    var body: some View {
        Group {
            if historyViewModel.items.isEmpty && !historyViewModel.isLoading {
                EmptyStateView(
                    hasFilters: historyViewModel.hasActiveFilters,
                    openSettings: openSettings
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            // v0.18: 使用 List 替代 ScrollView+LazyVStack 实现真正的视图回收
            // List 基于 NSTableView，具有视图回收能力，10k 项目内存从 ~500MB 降至 ~50MB
            ScrollViewReader { proxy in
                let _ = ScrollPerformanceProfile.incrementCounter(name: "list.body")
                List {
                    // Loading indicator
                    // `items.isEmpty` first: `isLoading` is only observed while the list is empty.
                    if historyViewModel.items.isEmpty && historyViewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, ScopySpacing.md)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    // v0.21: 使用局部变量缓存计算属性结果，避免多次访问触发 @Observable 追踪
                    // 这样 SwiftUI 只追踪一次 pinnedItems/unpinnedItems 访问
                    let pinned = historyViewModel.pinnedItems
                    let unpinned = historyViewModel.unpinnedItems
                    // Rows are built inside ForEach child closures, where every @Observable read installs its own
                    // observation and copies the access list; read the shared state once here and pass values down.
                    let rowContext = HistoryRowContext(
                        settings: settingsViewModel.settings,
                        activePopover: activePopover,
                        isPreviewPinningActive: pinnedPreviewController.isPinned,
                        searchMatchContexts: historyViewModel.searchMatchContexts
                    )

                    // v0.18: 不使用 Section header，改为普通行以避免黑色背景
                    // Pinned Section Header
                    if !pinned.isEmpty {
                        SectionHeader(
                            title: "Pinned",
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

                    // Recent Section Header
                    RecentSectionHeader(count: unpinned.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

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
                    historyViewModel.rowSelection.onSelectionChanged = { id, follow in
                        guard follow, let id else { return }
                        programmaticScrollGate.beginProgrammaticScroll()
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onDisappear {
                    historyViewModel.rowSelection.onSelectionChanged = nil
                }
                // 单条删除快捷键: Option+Delete
                .onKeyPress { keyPress in
                    if keyPress.key == .delete && keyPress.modifiers.contains(.option) {
                        Task { await historyViewModel.deleteSelectedItem() }
                        return .handled
                    }
                    return .ignored
                }
            }
        }
        }
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
        lastDismissedPopover = HoverPreviewDismissSnapshot(itemID: itemID, at: CFAbsoluteTimeGetCurrent())
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
        guard let snapshot = lastDismissedPopover, snapshot.itemID == itemID else { return 0 }
        let elapsed = CFAbsoluteTimeGetCurrent() - snapshot.at
        let remaining = Self.popoverReopenCooldownSeconds - elapsed
        return remaining > 0 ? remaining : 0
    }

    /// Moves the preview a row is showing into the pinned window.
    ///
    /// The popover is dismissed first so the shared Markdown WebView is released before the
    /// window's host claims it; presenting on the next run loop turn keeps that hand-off in the
    /// same order the popover-to-popover transition already uses.
    @MainActor
    private func pinPreview(
        item: ClipboardItemDTO,
        kind: HoverPreviewPopoverKind,
        model: HoverPreviewModel,
        revision: ClipboardItemContentRevision
    ) {
        let filePreview = kind == .file
            ? FilePreviewSupport.previewSummary(from: item.plainText, requireExists: true)
            : nil
        detachSharedMarkdownWebViewIfAttached()
        pendingPopover = nil
        activePopover = nil

        DispatchQueue.main.async {
            pinnedPreviewController.pin(
                item: item,
                revision: revision,
                kind: kind,
                filePreviewKind: filePreview?.kind,
                filePreviewPath: filePreview?.path,
                source: model,
                settingsViewModel: settingsViewModel,
                markdownWebViewController: sharedMarkdownPreviewController
            )
        }
    }

    @MainActor
    private func presentPopover(itemID: UUID, kind: HoverPreviewPopoverKind) {
        // One preview at a time: a pinned window holds the shared Markdown WebView.
        guard !pinnedPreviewController.isPinned else { return }
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
        let activePopover: HoverPreviewPopoverState?
        let isPreviewPinningActive: Bool
        let searchMatchContexts: [UUID: SearchMatchContext]
    }

    private func historyRow(item: ClipboardItemDTO, context: HistoryRowContext) -> some View {
        HistorySelectionAwareRow(itemID: item.id, selectionFanout: historyViewModel.rowSelection) { isSelected in
            historyRowContent(item: item, context: context, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func historyRowContent(
        item: ClipboardItemDTO,
        context: HistoryRowContext,
        isSelected: Bool
    ) -> some View {
        let activePopover = context.activePopover
        let isImagePreviewPresented = activePopover?.itemID == item.id && activePopover?.kind == .image
        let isTextPreviewPresented = activePopover?.itemID == item.id && activePopover?.kind == .text
        let isFilePreviewPresented = activePopover?.itemID == item.id && activePopover?.kind == .file
        let row = HistoryItemView(
            item: item,
            isKeyboardSelected: isSelected,
            settings: context.settings,
            searchMatchContext: context.searchMatchContexts[item.id],
            onSelect: { Task { await historyViewModel.select(item) } },
            onSelectOptimizedForCodex: { Task { await historyViewModel.selectOptimizedForCodex(item) } },
            onSendViaAirDrop: { Task { await historyViewModel.sendViaAirDrop(item) } },
            onOpenContainingFolder: { Task { await historyViewModel.openContainingFolder(item) } },
            onHoverSelect: { id in
                // Source first: the selection fan-out reads it when `selectedID` changes.
                historyViewModel.lastSelectionSource = .mouse
                historyViewModel.selectedID = id
            },
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
            isPreviewPinningActive: context.isPreviewPinningActive,
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

/// Keeps the high-frequency scroll flag out of `HistoryListView.body`'s Observation dependency
/// set. Only this small header redraws when scrolling starts or ends; row construction remains
/// driven by item/selection/popover changes.
/// Reads `isScrolling` and `performanceSummary` here, not in the List body: both change per
/// search or scroll and would otherwise rebuild every row.
private struct RecentSectionHeader: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let count: Int

    var body: some View {
        SectionHeader(
            title: "Recent",
            count: count,
            performanceSummary: historyViewModel.performanceSummary,
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

/// Holds one row's selection as local state fed by `HistoryRowSelectionFanout`, so a selection change
/// re-evaluates the two rows it concerns instead of the List body (which re-initializes every ForEach
/// child and diffs every loaded id).
private struct HistorySelectionAwareRow<Content: View>: View {
    @Environment(HistoryViewModel.self) private var historyViewModel

    let itemID: UUID
    let selectionFanout: HistoryRowSelectionFanout
    let content: (Bool) -> Content
    @State private var isSelected: Bool

    init(
        itemID: UUID,
        selectionFanout: HistoryRowSelectionFanout,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.itemID = itemID
        self.selectionFanout = selectionFanout
        self.content = content
        _isSelected = State(initialValue: selectionFanout.isSelected(itemID))
    }

    var body: some View {
        content(isSelected)
            .onAppear {
                isSelected = selectionFanout.register(itemID: itemID) { selected in
                    isSelected = selected
                }
                historyViewModel.rowDidAppear(itemID: itemID)
            }
            .onDisappear {
                selectionFanout.unregister(itemID: itemID)
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
