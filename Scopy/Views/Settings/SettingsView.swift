import SwiftUI
import ScopyKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsViewModel.self) private var settingsViewModel

    @State private var selection: SettingsPage? = .general
    @State private var sidebarSearchText = ""
    @State private var tempSettings: SettingsDTO?
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
                tempSettings = settingsViewModel.settings
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
        let isDirty = settings.wrappedValue != settingsViewModel.settings

        return VStack(spacing: 0) {
            NavigationSplitView {
                List(filteredPages, selection: $selection) { page in
                    SettingsSidebarRow(page: page)
                        .tag(page)
                }
                .listStyle(.sidebar)
                .searchable(text: $sidebarSearchText, placement: .sidebar, prompt: "搜索设置")
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
            }
            .navigationSplitViewColumnWidth(240)
            .frame(minWidth: ScopySize.Window.settingsWidth, minHeight: ScopySize.Window.settingsHeight)

            SettingsActionBar(
                isSaving: isSaving,
                isDirty: isDirty,
                savedHint: savedHint,
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
                    savedHint = "已保存"
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
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: ScopySpacing.md) {
                Button("恢复默认", action: onReset)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("Settings.ResetButton")

                Spacer()

                if let savedHint {
                    Text(savedHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("Settings.CancelButton")

                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || isSaving)
                    .accessibilityIdentifier("Settings.SaveButton")
            }
            .padding(.horizontal, ScopySpacing.xl)
            .padding(.vertical, ScopySpacing.md)
            .background(.regularMaterial)
        }
    }
}

#if canImport(AppKit)
private struct SettingsSidebarRow: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: ScopySpacing.md) {
            SettingsSymbolIcon(systemName: page.icon, tint: iconColor, size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(page.title)
                    .font(ScopyTypography.sidebarLabel)
                if let subtitle = page.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var iconColor: Color {
        switch page {
        case .general:
            return .gray
        case .shortcuts:
            return .purple
        case .clipboard:
            return .green
        case .appearance:
            return .orange
        case .storage:
            return .blue
        case .about:
            return .secondary
        }
    }
}
#endif

private struct SettingsSymbolIcon: View {
    let systemName: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.18))
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.system(size: size * 0.55, weight: .semibold))
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    SettingsView()
        .environment(AppState.shared)
        .environment(AppState.shared.historyViewModel)
        .environment(AppState.shared.settingsViewModel)
}
