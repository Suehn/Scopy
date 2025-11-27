import SwiftUI

/// 底部状态栏视图
struct FooterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            // 统计信息
            HStack(spacing: 8) {
                if !appState.searchQuery.isEmpty {
                    Text("\(appState.items.count) results")
                } else if appState.loadedCount < appState.totalCount {
                    Text("\(appState.loadedCount) / \(appState.totalCount) items")
                } else {
                    Text("\(appState.totalCount) items")
                }

                Text("•")
                Text(appState.storageSizeText)

                if appState.canLoadMore && !appState.searchQuery.isEmpty {
                    Text("•")
                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button("Load more") {
                            Task { await appState.loadMore() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            // 操作按钮
            HStack(spacing: 12) {
                FooterButton(title: "Clear", shortcut: "⌘⌫") {
                    Task { await appState.clearAll() }
                }

                FooterButton(title: "Settings", shortcut: "⌘,") {
                    appState.appDelegate?.openSettings()
                }

                FooterButton(title: "Quit", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// 底部按钮组件
struct FooterButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Color.accentColor.opacity(0.8) : Color.clear)
            .foregroundStyle(isHovered ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
