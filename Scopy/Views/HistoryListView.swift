import SwiftUI

/// 历史列表视图 - 符合 v0.md 的懒加载设计
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.items.isEmpty && !appState.isLoading {
            EmptyStateView(
                hasFilters: appState.hasActiveFilters,
                openSettings: appState.openSettingsHandler
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // v0.18: 使用 List 替代 ScrollView+LazyVStack 实现真正的视图回收
            // List 基于 NSTableView，具有视图回收能力，10k 项目内存从 ~500MB 降至 ~50MB
            ScrollViewReader { proxy in
                List {
                    // Loading indicator
                    if appState.isLoading && appState.items.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, ScopySpacing.md)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    // v0.21: 使用局部变量缓存计算属性结果，避免多次访问触发 @Observable 追踪
                    // 这样 SwiftUI 只追踪一次 pinnedItems/unpinnedItems 访问
                    let pinned = appState.pinnedItems
                    let unpinned = appState.unpinnedItems

                    // v0.18: 不使用 Section header，改为普通行以避免黑色背景
                    // Pinned Section Header
                    if !pinned.isEmpty && appState.searchQuery.isEmpty {
                        SectionHeader(
                            title: "Pinned",
                            count: pinned.count,
                            isCollapsible: true,
                            isCollapsed: appState.isPinnedCollapsed,
                            onToggle: { appState.isPinnedCollapsed.toggle() }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        // Pinned Items
                        if !appState.isPinnedCollapsed {
                            ForEach(pinned) { item in
                                historyRow(item: item)
                            }
                        }
                    }

                    // Recent Section Header
                    SectionHeader(
                        title: "Recent",
                        count: unpinned.count,
                        performanceSummary: appState.performanceSummary
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    // Recent Items
                    ForEach(unpinned) { item in
                        historyRow(item: item)
                    }

                    // Load More Trigger
                    if appState.canLoadMore {
                        LoadMoreTriggerView(isLoading: appState.isLoading)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                Task { await appState.loadMore() }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .onChange(of: appState.selectedID) { _, newValue in
                    // 仅当键盘导航时自动滚动到选中项
                    if let id = newValue, appState.lastSelectionSource == .keyboard {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                // 单条删除快捷键: Option+Delete
                .onKeyPress { keyPress in
                    if keyPress.key == .delete && keyPress.modifiers.contains(.option) {
                        Task { await appState.deleteSelectedItem() }
                        return .handled
                    }
                    return .ignored
                }
            }
        }
    }

    /// v0.18: 添加 List 修饰符以保持原有样式
    @ViewBuilder
    private func historyRow(item: ClipboardItemDTO) -> some View {
        HistoryItemView(
            item: item,
            isKeyboardSelected: appState.selectedID == item.id,
            settings: appState.settings,
            onSelect: { Task { await appState.select(item) } },
            onHoverSelect: { id in
                appState.selectedID = id
                appState.lastSelectionSource = .mouse
            },
            onTogglePin: { Task { await appState.togglePin(item) } },
            onDelete: { Task { await appState.delete(item) } },
            getImageData: { try? await appState.service.getImageData(itemID: item.id) }
        )
        .equatable()
        .id(item.id)
        .listRowInsets(EdgeInsets())      // 移除默认内边距
        .listRowBackground(Color.clear)    // 透明背景
        .listRowSeparator(.hidden)         // 隐藏分隔线
    }
}
