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
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            switch appState.startupPhase {
            case .idle, .starting:
                StartupLoadingView()
            case .running:
                mainContent
            case .startupFailed(let failure):
                StartupFailureView(
                    failure: failure,
                    onRetry: {
                        Task { await appState.start() }
                    },
                    onCopyDiagnostics: {
                        appState.copyStartupDiagnosticsToPasteboard()
                    },
                    openSettings: appState.openSettingsHandler
                )
            }
        }
        .onAppear {
            if appState.startupPhase == .running {
                searchFocused = true
                Task {
                    await historyViewModel.loadIfStale()
                }
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

    private var mainContent: some View {
        @Bindable var bindableHistory = historyViewModel

        return VStack(alignment: .leading, spacing: 0) {
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

private struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: ScopySpacing.md) {
            ProgressView()
                .controlSize(.regular)
            Text("Starting Scopy…")
                .font(ScopyTypography.title)
            Text("Initializing clipboard service and loading recent history")
                .font(ScopyTypography.caption)
                .foregroundStyle(ScopyColors.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ScopySpacing.xl)
    }
}

private struct StartupFailureView: View {
    let failure: StartupFailure
    let onRetry: () -> Void
    let onCopyDiagnostics: () -> Void
    let openSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: ScopySpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: ScopySize.Icon.empty))
                .foregroundStyle(.yellow)

            VStack(spacing: ScopySpacing.xs) {
                Text("Failed to start Scopy")
                    .font(ScopyTypography.title)
                Text("Clipboard history is unavailable until the startup issue is resolved.")
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
                    .multilineTextAlignment(.center)
            }

            Text(failure.message)
                .font(ScopyTypography.caption)
                .foregroundStyle(ScopyColors.tertiaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, ScopySpacing.xl)

            HStack(spacing: ScopySpacing.sm) {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button("Copy Diagnostics", action: onCopyDiagnostics)
                    .buttonStyle(.bordered)

                if let openSettings {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ScopySpacing.xl)
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
