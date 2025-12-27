import Foundation
import SwiftUI
import ScopyKit
import ScopyUISupport

/// Hover preview popover kind used to coordinate a single active preview across the list.
enum HoverPreviewPopoverKind: Equatable {
    case image
    case text
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

    @Environment(AppState.self) private var appState
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel

    // Shared Markdown preview controller to avoid repeatedly creating/destroying WebKit views/processes.
    @StateObject private var sharedMarkdownPreviewController = MarkdownPreviewWebViewController()

    // Enforce that at most one hover preview popover is presented at a time.
    @State private var activePopover: HoverPreviewPopoverState?
    @State private var pendingPopover: HoverPreviewPopoverState?
    @State private var lastDismissedPopover: HoverPreviewDismissSnapshot?

    private static let popoverReopenCooldownSeconds: CFTimeInterval = 0.25

    private static let isUITesting: Bool = ProcessInfo.processInfo.arguments.contains("--uitesting")
    private static let profileAccessibility: Bool = ProcessInfo.processInfo.environment["SCOPY_PROFILE_ACCESSIBILITY"] == "1"
    private static let shouldExposeAccessibility: Bool = isUITesting || profileAccessibility

    var body: some View {
        if historyViewModel.items.isEmpty && !historyViewModel.isLoading {
            EmptyStateView(
                hasFilters: historyViewModel.hasActiveFilters,
                openSettings: appState.openSettingsHandler
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // v0.18: 使用 List 替代 ScrollView+LazyVStack 实现真正的视图回收
            // List 基于 NSTableView，具有视图回收能力，10k 项目内存从 ~500MB 降至 ~50MB
            ScrollViewReader { proxy in
                List {
                    // Loading indicator
                    if historyViewModel.isLoading && historyViewModel.items.isEmpty {
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

                    // v0.18: 不使用 Section header，改为普通行以避免黑色背景
                    // Pinned Section Header
                    if !pinned.isEmpty && historyViewModel.searchQuery.isEmpty {
                        SectionHeader(
                            title: "Pinned",
                            count: pinned.count,
                            isScrolling: historyViewModel.isScrolling,
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
                                historyRow(item: item)
                            }
                        }
                    }

                    // Recent Section Header
                    SectionHeader(
                        title: "Recent",
                        count: unpinned.count,
                        performanceSummary: historyViewModel.performanceSummary,
                        isScrolling: historyViewModel.isScrolling
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    // Recent Items
                    ForEach(unpinned) { item in
                        historyRow(item: item)
                    }

                    // Load More Trigger
                    if historyViewModel.canLoadMore {
                        LoadMoreTriggerView(isLoading: historyViewModel.isLoading)
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
                        onScrollStart: { historyViewModel.scrollDidStart() },
                        onScrollEnd: { historyViewModel.scrollDidEnd() },
                        onScrollViewAttach: ScrollPerformanceProfile.isEnabled ? { scrollView in
                            ScrollPerformanceProfile.shared.attachScrollView(scrollView)
                        } : nil
                    )
                )
                .background(ScrollFrameSamplerView())
                .onChange(of: historyViewModel.selectedID) { _, newValue in
                    // 仅当键盘导航时自动滚动到选中项
                    if let id = newValue, historyViewModel.lastSelectionSource == .keyboard {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
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

    // MARK: - Preview Popover Coordination

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

        if let existing = activePopover {
            recordPopoverDismiss(itemID: existing.itemID)
        }
        pendingPopover = nil
        activePopover = nil
        detachSharedMarkdownWebViewIfAttached()
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

    @MainActor
    private func presentPopover(itemID: UUID, kind: HoverPreviewPopoverKind) {
        let next = HoverPreviewPopoverState(itemID: itemID, kind: kind)
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
    @ViewBuilder
    private func historyRow(item: ClipboardItemDTO) -> some View {
        let isSelected = historyViewModel.selectedID == item.id
        let isImagePreviewPresented = activePopover?.itemID == item.id && activePopover?.kind == .image
        let isTextPreviewPresented = activePopover?.itemID == item.id && activePopover?.kind == .text
        let row = HistoryItemView(
            item: item,
            isKeyboardSelected: isSelected,
            isScrolling: historyViewModel.isScrolling,
            settings: settingsViewModel.settings,
            onSelect: { Task { await historyViewModel.select(item) } },
            onHoverSelect: { id in
                historyViewModel.selectedID = id
                historyViewModel.lastSelectionSource = .mouse
            },
            onTogglePin: { Task { await historyViewModel.togglePin(item) } },
            onDelete: { Task { await historyViewModel.delete(item) } },
            onOptimizeImage: { await historyViewModel.optimizeImage(item) },
            getImageData: { try? await historyViewModel.getImageData(itemID: item.id) },
            markdownWebViewController: sharedMarkdownPreviewController,
            isImagePreviewPresented: isImagePreviewPresented,
            isTextPreviewPresented: isTextPreviewPresented,
            requestPopover: { kind in
                guard let kind else {
                    dismissPopoverIfActive(itemID: item.id)
                    return
                }
                presentPopover(itemID: item.id, kind: kind)
            },
            dismissOtherPopovers: {
                dismissAnyPopover(except: item.id)
            }
        )
        .equatable()
        .id(item.id)

        Group {
            if Self.shouldExposeAccessibility {
                row.accessibilityIdentifier("History.Item.\(item.id.uuidString)")
                    .accessibilityValue(isSelected ? "selected" : "unselected")
            } else {
                row
            }
        }
        .listRowInsets(EdgeInsets())      // 移除默认内边距
        .listRowBackground(Color.clear)    // 透明背景
        .listRowSeparator(.hidden)         // 隐藏分隔线
    }
}

private struct ScrollFrameSamplerView: View {
    var body: some View {
        if ScrollPerformanceProfile.isEnabled {
            TimelineView(.animation) { context in
                Color.clear
                    .onChange(of: context.date) { _, newValue in
                        ScrollPerformanceProfile.shared.recordFrameTick(newValue)
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
