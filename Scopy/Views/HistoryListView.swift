import SwiftUI

/// 历史列表视图 - 符合 v0.md 的懒加载设计
struct HistoryListView: View {
    @FocusState.Binding var searchFocused: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // 固定项（置顶）
                    if !appState.pinnedItems.isEmpty && appState.searchQuery.isEmpty {
                        ForEach(appState.pinnedItems) { item in
                            HistoryItemView(item: item)
                        }

                        Divider()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                    }

                    // 普通项
                    ForEach(appState.unpinnedItems) { item in
                        HistoryItemView(item: item)
                    }

                    // 加载更多触发器
                    if appState.canLoadMore && appState.searchQuery.isEmpty {
                        LoadMoreTriggerView(isLoading: appState.isLoading)
                            .onAppear {
                                Task {
                                    await appState.loadMore()
                                }
                            }
                    }
                }
            }
            .onChange(of: appState.selectedID) { _, newValue in
                if let id = newValue {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

/// 单个历史项视图
struct HistoryItemView: View {
    let item: ClipboardItemDTO

    @Environment(AppState.self) private var appState

    private var isSelected: Bool {
        appState.selectedID == item.id
    }

    private var appIcon: NSImage? {
        guard let bundleID = item.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 图标（显示来源 App）
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .padding(.leading, 4)
                    .padding(.vertical, 5)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 15, height: 15)
                    .padding(.leading, 4)
                    .padding(.vertical, 5)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(width: 8)

            // 文本内容
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13))
                .padding(.trailing, 5)

            Spacer()

            // Pin 图标
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.trailing, 8)
            }
        }
        .frame(minHeight: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .background(isSelected ? Color.accentColor.opacity(0.8) : .white.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .id(item.id)
        .onTapGesture {
            Task {
                await appState.select(item)
            }
        }
        .onHover { hovering in
            if hovering {
                appState.selectedID = item.id
            }
        }
        .contextMenu {
            Button("Copy") {
                Task { await appState.select(item) }
            }
            Button(item.isPinned ? "Unpin" : "Pin") {
                Task { await appState.togglePin(item) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await appState.delete(item) }
            }
        }
    }
}

/// 加载更多触发视图
struct LoadMoreTriggerView: View {
    var isLoading: Bool

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Scroll for more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(height: 30)
        .padding(.vertical, 5)
    }
}
