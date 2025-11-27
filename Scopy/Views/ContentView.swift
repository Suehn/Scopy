import SwiftUI

/// 主内容视图 - 对应 Maccy 的 ContentView
struct ContentView: View {
    @State private var appState = AppState.shared
    @FocusState private var searchFocused: Bool
    @State private var showClearConfirmation = false

    var body: some View {
        ZStack {
            // 背景模糊效果
            VisualEffectView()

            VStack(alignment: .leading, spacing: 0) {
                // 头部搜索框
                HeaderView(
                    searchQuery: $appState.searchQuery,
                    searchFocused: $searchFocused
                )

                // 历史列表
                HistoryListView(searchFocused: $searchFocused)

                // 底部状态栏
                FooterView()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 5)
        }
        .environment(appState)
        .onAppear {
            searchFocused = true
            Task {
                await appState.load()
            }
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .alert("Clear All History", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                Task { await appState.clearAll() }
            }
        } message: {
            Text("This will permanently delete all clipboard history. This action cannot be undone.")
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // ⌥⌫ (Option+Delete) - 删除选中项
        if keyPress.key == .delete && keyPress.modifiers.contains(.option) {
            Task { await appState.deleteSelectedItem() }
            return .handled
        }

        // ⌘⌫ (Command+Delete) - 清空历史（需要确认）
        if keyPress.key == .delete && keyPress.modifiers.contains(.command) {
            showClearConfirmation = true
            return .handled
        }

        switch keyPress.key {
        case .downArrow:
            appState.highlightNext()
            return .handled
        case .upArrow:
            appState.highlightPrevious()
            return .handled
        case .return:
            Task { await appState.selectCurrent() }
            return .handled
        case .escape:
            if !appState.searchQuery.isEmpty {
                appState.searchQuery = ""
                appState.search()
            } else {
                appState.closePanelHandler?()
            }
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    ContentView()
        .frame(width: 320, height: 400)
}
