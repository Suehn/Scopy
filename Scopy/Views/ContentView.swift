import SwiftUI
import ScopyKit

/// 主内容视图 - 对应 Maccy 的 ContentView
/// v0.10.1: 改用 Environment 注入 AppState，保持与 SettingsView 一致
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryViewModel.self) private var historyViewModel
    @FocusState private var searchFocused: Bool
    @State private var showClearConfirmation = false

    var body: some View {
        @Bindable var bindableHistory = historyViewModel
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HeaderView(
                    searchQuery: $bindableHistory.searchQuery,
                    searchFocused: $searchFocused
                )
                .padding(.horizontal, ScopySpacing.md)
                .padding(.top, ScopySpacing.md)
                .padding(.bottom, ScopySpacing.sm)

                HistoryListView(searchFocused: $searchFocused)

                FooterView()
            }
        }
        .onAppear {
            searchFocused = true
            Task {
                await historyViewModel.loadIfStale()
            }
        }
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .alert("Clear All History", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                Task { await historyViewModel.clearAll() }
            }
        } message: {
            Text("This will permanently delete all clipboard history. This action cannot be undone.")
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // ⌥⌫ (Option+Delete) - 删除选中项
        if keyPress.key == .delete && keyPress.modifiers.contains(.option) {
            Task { await historyViewModel.deleteSelectedItem() }
            return .handled
        }

        // ⌘⌫ (Command+Delete) - 清空历史（需要确认）
        if keyPress.key == .delete && keyPress.modifiers.contains(.command) {
            showClearConfirmation = true
            return .handled
        }

        switch keyPress.key {
        case .downArrow:
            historyViewModel.highlightNext()
            return .handled
        case .upArrow:
            historyViewModel.highlightPrevious()
            return .handled
        case .return:
            Task { await historyViewModel.selectCurrent() }
            return .handled
        case .escape:
            if !historyViewModel.searchQuery.isEmpty {
                historyViewModel.searchQuery = ""
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
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    ContentView()
        .environment(AppState.shared)
        .environment(AppState.shared.historyViewModel)
        .environment(AppState.shared.settingsViewModel)
        .frame(width: ScopySize.Window.mainWidth, height: ScopySize.Window.mainHeight)
}
