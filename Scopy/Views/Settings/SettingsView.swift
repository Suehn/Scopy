import SwiftUI
import ScopyKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsViewModel.self) private var settingsViewModel

    @State private var selection: SettingsPage? = .general
    @State private var tempSettings: SettingsDTO?
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    @State private var storageStats: StorageStatsDTO?
    @State private var isLoadingStats = false
    @State private var statsTask: Task<Void, Never>?

    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if let tempSettings {
                settingsContent(settings: Binding(get: { tempSettings }, set: { self.tempSettings = $0 }))
            } else {
                loadingView
            }
        }
        .onAppear {
            tempSettings = settingsViewModel.settings
            refreshStats()
        }
        .onDisappear {
            statsTask?.cancel()
            statsTask = nil
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { saveErrorMessage = nil }
                }
            )
        ) {
            Button("好") { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在加载设置…")
                .foregroundStyle(.secondary)
        }
        .frame(width: ScopySize.Window.settingsWidth, height: ScopySize.Window.settingsHeight)
    }

    private func settingsContent(settings: Binding<SettingsDTO>) -> some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsPage.allCases, selection: $selection) { page in
                    Label(page.title, systemImage: page.icon)
                        .font(ScopyTypography.sidebarLabel)
                        .tag(page)
                }
                .listStyle(.sidebar)
                .frame(minWidth: ScopySize.Width.sidebarMin)
            } detail: {
                Group {
                    switch selection ?? .general {
                    case .general:
                        GeneralSettingsPage(tempSettings: settings)
                    case .shortcuts:
                        ShortcutsSettingsPage(tempSettings: settings)
                    case .clipboard:
                        ClipboardSettingsPage(tempSettings: settings)
                    case .appearance:
                        AppearanceSettingsPage(tempSettings: settings)
                    case .storage:
                        StorageSettingsPage(
                            tempSettings: settings,
                            storageStats: storageStats,
                            isLoading: isLoadingStats,
                            onRefresh: refreshStats
                        )
                    case .about:
                        AboutSettingsPage()
                    }
                }
                .padding(.horizontal, ScopySpacing.lg)
                .padding(.vertical, ScopySpacing.md)
            }
            .navigationSplitViewColumnWidth(240)
            .frame(minWidth: ScopySize.Window.settingsWidth, minHeight: ScopySize.Window.settingsHeight)

            SettingsActionBar(
                isSaving: isSaving,
                onReset: { tempSettings = .default },
                onCancel: { onDismiss?() },
                onSave: saveSettings
            )
        }
        .frame(minWidth: ScopySize.Window.settingsWidth, minHeight: ScopySize.Window.settingsHeight)
    }

    private func refreshStats() {
        statsTask?.cancel()
        isLoadingStats = true

        statsTask = Task {
            do {
                guard !Task.isCancelled else { return }
                let stats = try await settingsViewModel.getDetailedStorageStats()
                guard !Task.isCancelled else { return }
                storageStats = stats
            } catch {
                if !Task.isCancelled {
                    ScopyLog.ui.error("Failed to load storage stats: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !Task.isCancelled {
                isLoadingStats = false
            }
        }
    }

    private func saveSettings() {
        guard let currentSettings = tempSettings else {
            ScopyLog.ui.warning("saveSettings: tempSettings is nil, skipping save")
            return
        }

        isSaving = true

        Task {
            do {
                try await settingsViewModel.updateSettingsOrThrow(currentSettings)
                await MainActor.run {
                    isSaving = false
                    onDismiss?()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct SettingsActionBar: View {
    let isSaving: Bool
    let onReset: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            Button("恢复默认", action: onReset)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("Settings.ResetButton")

            Spacer()

            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Settings.CancelButton")

            Button("保存", action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .accessibilityIdentifier("Settings.SaveButton")
        }
        .padding(.horizontal, ScopySpacing.xxl)
        .padding(.vertical, ScopySpacing.lg)
        .background(ScopyColors.secondaryBackground)
    }
}

#Preview {
    SettingsView()
        .environment(AppState.shared)
        .environment(AppState.shared.historyViewModel)
        .environment(AppState.shared.settingsViewModel)
}

