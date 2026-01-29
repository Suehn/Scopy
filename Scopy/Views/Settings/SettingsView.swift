import SwiftUI
import ScopyKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsViewModel.self) private var settingsViewModel

    @State private var selection: SettingsPage? = .general
    @State private var sidebarSearchText = ""
    @State private var tempSettings: SettingsDTO?
    @State private var baselineSettings: SettingsDTO?
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var savedHint: String?

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
            Task { @MainActor in
                await settingsViewModel.loadSettings()
                let loaded = settingsViewModel.settings
                baselineSettings = loaded
                tempSettings = loaded
            }
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

    private var filteredPages: [SettingsPage] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsPage.allCases }

        return SettingsPage.allCases.filter { page in
            page.title.localizedCaseInsensitiveContains(query)
                || (page.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func settingsContent(settings: Binding<SettingsDTO>) -> some View {
        let baseline = baselineSettings ?? settingsViewModel.settings
        let patch = SettingsPatch.from(baseline: baseline, draft: settings.wrappedValue)
            .droppingHotkey()
        let isDirty = !patch.isEmpty

        return NavigationSplitView {
            List(filteredPages, selection: $selection) { page in
                SettingsSidebarRow(page: page)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .searchable(text: $sidebarSearchText, placement: .sidebar, prompt: "搜索")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ScopyColors.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsActionBar(
                    isSaving: isSaving,
                    isDirty: isDirty,
                    savedHint: savedHint,
                    onReset: {
                        guard let current = tempSettings else {
                            tempSettings = .default
                            return
                        }
                        var reset = SettingsDTO.default
                        reset.hotkeyKeyCode = current.hotkeyKeyCode
                        reset.hotkeyModifiers = current.hotkeyModifiers
                        tempSettings = reset
                    },
                    onCancel: { onDismiss?() },
                    onSave: saveSettings
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
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
                await MainActor.run {
                    storageStats = stats
                }
            } catch {
                if !Task.isCancelled {
                    ScopyLog.ui.error("Failed to load storage stats: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isLoadingStats = false
            }
        }
    }

    private func saveSettings() {
        guard let baselineSettings, let currentSettings = tempSettings else {
            ScopyLog.ui.warning("saveSettings: baselineSettings or tempSettings is nil, skipping save")
            return
        }

        isSaving = true

        Task {
            do {
                let patch = SettingsPatch.from(baseline: baselineSettings, draft: currentSettings)
                    .droppingHotkey()
                guard !patch.isEmpty else {
                    await MainActor.run {
                        isSaving = false
                        onDismiss?()
                    }
                    return
                }

                let latest = (try? await settingsViewModel.getLatestSettingsOrThrow()) ?? baselineSettings
                let merged = latest.applying(patch)
                try await settingsViewModel.updateSettingsOrThrow(merged)
                await MainActor.run {
                    isSaving = false
                    savedHint = "已保存"
                    self.baselineSettings = merged
                    tempSettings = merged
                    onDismiss?()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        if savedHint == "已保存" {
                            savedHint = nil
                        }
                    }
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
    let isDirty: Bool
    let savedHint: String?
    let onReset: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("恢复默认", action: onReset)
                .buttonStyle(.link)
                .controlSize(.small)
                .accessibilityIdentifier("Settings.ResetButton")

            Spacer()

            if let savedHint {
                Text(savedHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Settings.CancelButton")

            Button("保存", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty || isSaving)
                .accessibilityIdentifier("Settings.SaveButton")
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }
}

#if canImport(AppKit)
private struct SettingsSidebarRow: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 8) {
            SettingsSymbolIcon(systemName: page.icon, tint: iconColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(page.title)
                    .font(.body)
                    .fontWeight(.regular)

                if let subtitle = page.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6) // Standard macOS Settings row height
    }

    private var iconColor: Color {
        switch page {
        case .general:
            return .gray // macOS standard for General is gray
        case .shortcuts:
            return .purple
        case .clipboard:
            return .green
        case .appearance:
            return .orange
        case .storage:
            return .blue
        case .about:
            return .gray
        }
    }
}
#endif

private struct SettingsSymbolIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint)
                .frame(width: 26, height: 26) // Slightly larger, standard macOS size

            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState.shared)
        .environment(AppState.shared.historyViewModel)
        .environment(AppState.shared.settingsViewModel)
}
