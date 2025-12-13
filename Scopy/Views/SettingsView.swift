import SwiftUI
import Carbon.HIToolbox
import ScopyKit

/// 设置窗口视图
/// v0.6: 多页 TabView 结构，支持快捷键自定义、搜索模式选择、存储统计
/// v0.10: 改用 Environment 注入 AppState，实现完全解耦
/// v0.10.1: 使用可选类型防止首帧默认值被误写
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsViewModel.self) private var settingsViewModel
    @Environment(HistoryViewModel.self) private var historyViewModel

    @State private var selection: SettingsPage? = .general
    @State private var tempSettings: SettingsDTO?  // v0.10.1: 可选类型，防止首帧默认值
    @State private var isSaving = false
    @State private var storageStats: StorageStatsDTO?
    @State private var isLoadingStats = false
    @State private var statsTask: Task<Void, Never>?  // v0.20: 保存 Task 引用，防止泄漏

    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if tempSettings != nil {
                settingsContent(
                    settings: Binding(
                        get: { tempSettings ?? .default },
                        set: { tempSettings = $0 }
                    )
                )
            } else {
                // 加载态：防止用户在设置加载前点击 Save
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading settings...")
                        .foregroundStyle(.secondary)
                }
                .frame(width: ScopySize.Window.settingsWidth, height: ScopySize.Window.settingsHeight)
            }
        }
        .onAppear {
            tempSettings = settingsViewModel.settings
            refreshStats()
        }
        .onDisappear {
            // v0.20: 取消未完成的任务，防止内存泄漏
            statsTask?.cancel()
            statsTask = nil
        }
    }

    @ViewBuilder
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
                        StorageSettingsTab(
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

            // Bottom action bar
            HStack {
                Button("Reset to Defaults") {
                    tempSettings = .default
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") {
                    onDismiss?()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveSettings()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.horizontal, ScopySpacing.xxl)
            .padding(.vertical, ScopySpacing.lg)
            .background(ScopyColors.secondaryBackground)
        }
        .frame(minWidth: ScopySize.Window.settingsWidth, minHeight: ScopySize.Window.settingsHeight)
    }

    /// v0.20: 保存 Task 引用，支持取消，防止内存泄漏
    private func refreshStats() {
        // 取消之前的任务
        statsTask?.cancel()

        isLoadingStats = true
        statsTask = Task {
            do {
                // 检查取消状态
                guard !Task.isCancelled else { return }
                let stats = try await settingsViewModel.getDetailedStorageStats()
                // 再次检查取消状态
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

    /// v0.22: 添加错误处理，确保 isSaving 状态正确重置
    private func saveSettings() {
        // v0.10.1: 防止在设置加载前保存
        guard let currentSettings = tempSettings else {
            ScopyLog.ui.warning("saveSettings: tempSettings is nil, skipping save")
            return
        }

        isSaving = true

        ScopyLog.ui.info(
            "saveSettings: keyCode=\(currentSettings.hotkeyKeyCode, privacy: .public), modifiers=0x\(String(currentSettings.hotkeyModifiers, radix: 16), privacy: .public)"
        )

        Task {
            await settingsViewModel.updateSettings(currentSettings)
            await MainActor.run {
                historyViewModel.searchMode = currentSettings.defaultSearchMode

                ScopyLog.ui.info("Updating hotkey via callback")
                appState.applyHotKeyHandler?(
                    currentSettings.hotkeyKeyCode,
                    currentSettings.hotkeyModifiers
                )

                isSaving = false
                onDismiss?()
            }
        }
    }
}

// MARK: - Settings Page Enum

private enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case shortcuts
    case clipboard
    case appearance
    case storage
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .clipboard: return "Clipboard"
        case .appearance: return "Appearance"
        case .storage: return "Storage"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .appearance: return "paintpalette"
        case .storage: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}

// MARK: - General Settings Page

struct GeneralSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        Form {
            Section {
                Picker("Default Search Mode", selection: $tempSettings.defaultSearchMode) {
                    Text("Exact").tag(SearchMode.exact)
                    Text("Fuzzy").tag(SearchMode.fuzzy)
                    Text("Fuzzy+").tag(SearchMode.fuzzyPlus)
                    Text("Regex").tag(SearchMode.regex)
                }
                .pickerStyle(.menu)
            } header: {
                Label("Search", systemImage: "magnifyingglass")
            } footer: {
                Text("Exact=精确 · Fuzzy=模糊 · Fuzzy+=分词模糊 · Regex=正则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts Page

struct ShortcutsSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        Form {
            // MARK: - Hotkey Section
            Section {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    HotKeyRecorderView(
                        keyCode: $tempSettings.hotkeyKeyCode,
                        modifiers: $tempSettings.hotkeyModifiers
                    )
                }
            } header: {
                Label("Shortcuts", systemImage: "keyboard")
            } footer: {
                Text("Click to record a new keyboard shortcut. Press Escape to cancel.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Clipboard Page

struct ClipboardSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        Form {
            Section {
                Toggle("Save Images", isOn: $tempSettings.saveImages)
                Toggle("Save Files", isOn: $tempSettings.saveFiles)
            } header: {
                Label("Content Types", systemImage: "doc.on.clipboard")
            } footer: {
                Text("Disable to skip saving specific content types to history.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance Page

struct AppearanceSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        Form {
            Section {
                Toggle("Show Thumbnails", isOn: $tempSettings.showImageThumbnails)

                if tempSettings.showImageThumbnails {
                    HStack {
                        Text("Thumbnail Height")
                        Spacer()
                        Picker("", selection: $tempSettings.thumbnailHeight) {
                            Text("30 px").tag(30)
                            Text("40 px").tag(40)
                            Text("50 px").tag(50)
                            Text("60 px").tag(60)
                        }
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                    }

                    HStack {
                        Text("Preview Delay")
                        Spacer()
                        Picker("", selection: $tempSettings.imagePreviewDelay) {
                            Text("0.5 sec").tag(0.5)
                            Text("1.0 sec").tag(1.0)
                            Text("1.5 sec").tag(1.5)
                            Text("2.0 sec").tag(2.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                    }
                }
            } footer: {
                Text("Show image thumbnails in history list. Hover to preview full image.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage Settings Tab

struct StorageSettingsTab: View {
    @Binding var tempSettings: SettingsDTO
    let storageStats: StorageStatsDTO?
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        Form {
            // MARK: - Limits Section
            Section {
                Picker("Maximum Items", selection: $tempSettings.maxItems) {
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                    Text("100,000").tag(100000)
                }
                .pickerStyle(.menu)

                Picker("Maximum Storage", selection: $tempSettings.maxStorageMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                }
                .pickerStyle(.menu)
            } header: {
                Label("Limits", systemImage: "gauge.with.dots.needle.bottom.50percent")
            } footer: {
                Text("Older items will be automatically removed when limits are exceeded.")
                    .foregroundStyle(.secondary)
            }

            // MARK: - Current Usage Section
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let stats = storageStats {
                    // Item count
                    HStack {
                        Text("Items")
                        Spacer()
                        Text("\(stats.itemCount) / \(tempSettings.maxItems)")
                            .foregroundStyle(.secondary)
                    }

                    // Database size
                    HStack {
                        Text("Database")
                        Spacer()
                        Text(stats.databaseSizeText)
                            .foregroundStyle(.secondary)
                    }

                    // External storage
                    HStack {
                        Text("External Storage")
                        Spacer()
                        Text(stats.externalStorageSizeText)
                            .foregroundStyle(.secondary)
                    }

                    // v0.15.2: Thumbnails
                    HStack {
                        Text("Thumbnails")
                        Spacer()
                        Text(stats.thumbnailSizeText)
                            .foregroundStyle(.secondary)
                    }

                    // Total
                    HStack {
                        Text("Total")
                            .fontWeight(.medium)
                        Spacer()
                        Text(stats.totalSizeText)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    // Refresh button
                    Button(action: onRefresh) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } else {
                    Text("Unable to load storage statistics")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Current Usage", systemImage: "chart.pie")
            }

            // MARK: - Location Section
            Section {
                HStack {
                    Text("Database Location")
                    Spacer()
                    Text(storageStats?.databasePath ?? "~/Library/Application Support/Scopy/")
                        .foregroundStyle(.secondary)
                        .font(ScopyTypography.pathLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Show in Finder") {
                    // v0.15: Use FileManager to get Application Support directory reliably
                    // This fixes the bug where button doesn't work when storageStats is nil
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let scopyDir = appSupport.appendingPathComponent("Scopy")

                    if FileManager.default.fileExists(atPath: scopyDir.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([scopyDir])
                    } else {
                        // Create directory if it doesn't exist, then open
                        try? FileManager.default.createDirectory(at: scopyDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([scopyDir])
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            } header: {
                Label("Location", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About Tab

struct AboutSettingsPage: View {
    @State private var performanceSummary: PerformanceSummary?
    @State private var memoryUsageMB: Double = 0
    /// v0.20: 使用 Task 替代 Timer，自动响应取消，避免内存泄漏
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: ScopySpacing.xl) {
            // App Icon and Version
            VStack(spacing: ScopySpacing.sm) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: ScopySize.Icon.appLogo))
                    .foregroundStyle(.blue)

                Text("Scopy")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version \(AppVersion.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, ScopySpacing.lg)

            Divider()
                .padding(.horizontal, ScopySpacing.xxxl)

            // Features - 紧凑两列布局
            GroupBox {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ScopySpacing.sm) {
                    FeatureRow(icon: "infinity", text: "Unlimited history")
                    FeatureRow(icon: "magnifyingglass", text: "FTS5 search")
                    FeatureRow(icon: "externaldrive", text: "Tiered storage")
                    FeatureRow(icon: "checkmark.circle", text: "Deduplication")
                    FeatureRow(icon: "keyboard", text: "Global hotkey")
                    FeatureRow(icon: "bolt", text: "High performance")
                }
            } label: {
                Text("Features")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, ScopySpacing.xxl)

            // Performance - GroupBox 样式
            GroupBox {
                VStack(alignment: .leading, spacing: ScopySpacing.md) {
                    // Search
                    HStack(alignment: .firstTextBaseline) {
                        Text("Search")
                            .font(.caption)
                            .frame(width: ScopySize.Width.statLabel, alignment: .leading)
                        Spacer()
                        if let summary = performanceSummary, summary.searchSamples > 0 {
                            Text("\(formatMs(summary.searchP95)) P95 / \(formatMs(summary.searchAvg)) avg (\(summary.searchSamples) samples)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("N/A")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Load
                    HStack(alignment: .firstTextBaseline) {
                        Text("Load")
                            .font(.caption)
                            .frame(width: ScopySize.Width.statLabel, alignment: .leading)
                        Spacer()
                        if let summary = performanceSummary, summary.loadSamples > 0 {
                            Text("\(formatMs(summary.loadP95)) P95 / \(formatMs(summary.loadAvg)) avg (\(summary.loadSamples) samples)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("N/A")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    // Memory Usage
                    HStack(alignment: .firstTextBaseline) {
                        Text("Memory")
                            .font(.caption)
                            .frame(width: ScopySize.Width.statLabel, alignment: .leading)
                        Spacer()
                        Text(String(format: "%.1f MB", memoryUsageMB))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                HStack {
                    Text("Performance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: refreshPerformance) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, ScopySpacing.xxl)

            Spacer()

            // Links
            HStack(spacing: ScopySpacing.xl) {
                Link("GitHub", destination: URL(string: "https://github.com")!)
                Link("Report Issue", destination: URL(string: "https://github.com")!)
            }
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.bottom, ScopySpacing.md)
        }
        .onAppear {
            refreshPerformance()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    private func refreshPerformance() {
        Task {
            performanceSummary = await PerformanceMetrics.shared.getSummary()
        }
        // 获取当前进程内存占用
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            memoryUsageMB = Double(info.resident_size) / 1024 / 1024
        }
    }

    /// v0.20: 使用 Task 替代 Timer，自动响应取消，避免内存泄漏
    private func startAutoRefresh() {
        autoRefreshTask = Task {
            while !Task.isCancelled {
                // 30 分钟自动刷新
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                refreshPerformance()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// 格式化毫秒数
    private func formatMs(_ ms: Double) -> String {
        if ms < 1 {
            return String(format: "%.2f ms", ms)
        } else if ms < 10 {
            return String(format: "%.1f ms", ms)
        } else {
            return String(format: "%.0f ms", ms)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: ScopySpacing.xl - ScopySpacing.sm) {
            Image(systemName: icon)
                .frame(width: ScopySize.Icon.md)
                .foregroundStyle(.blue)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - HotKey Recorder (ObservableObject)

/// 快捷键录制器 - 使用 class 以便在闭包中正确更新状态
/// v0.9.3: 使用回调方式直接更新 binding，避免 .onChange 时机问题
/// v0.10: 完全解耦，通过注入的回调与外部通信
@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published var isRecording = false

    /// 录制完成回调 - 直接更新 binding
    var onRecorded: ((UInt32, UInt32) -> Void)?

    /// 注销热键回调 - 用于录制期间暂停全局热键
    var unregisterHotKeyHandler: (() -> Void)?

    /// 应用热键回调 - 用于恢复全局热键
    var applyHotKeyHandler: ((UInt32, UInt32) -> Void)?

    private var eventMonitor: Any?
    private var globalEventMonitor: Any?
    private var previousHotKey: (keyCode: UInt32, modifiers: UInt32)?
    private var didRecordNewHotKey = false

    func startRecording(currentKeyCode: UInt32, currentModifiers: UInt32) {
        guard !isRecording else { return }

        isRecording = true
        didRecordNewHotKey = false
        previousHotKey = (currentKeyCode, currentModifiers)
        ScopyLog.ui.info("Started hotkey recording")

        // 通过注入的回调暂停当前全局热键（完全解耦）
        unregisterHotKeyHandler?()

        // 尝试前置窗口，减少焦点问题；全局监听兜底
        NSApp.activate(ignoringOtherApps: true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let modifiersRawValue = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                _ = self?.handleKeyDown(keyCode: keyCode, modifiersRawValue: modifiersRawValue)
            }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return handleKeyDown(keyCode: event.keyCode, modifiersRawValue: event.modifierFlags.rawValue)
    }

    private func handleKeyDown(keyCode: UInt16, modifiersRawValue: UInt) -> Bool {
        ScopyLog.ui.debug(
            "Key pressed: keyCode=\(keyCode, privacy: .public), modifiers=\(modifiersRawValue, privacy: .public)"
        )

        // ESC 取消录制并恢复原快捷键
        if keyCode == 53 {
            ScopyLog.ui.info("ESC pressed, cancelling recording")
            stopRecording(restorePrevious: true)
            return true
        }

        // 获取修饰键（转换为 Carbon 格式）
        let nsModifiers = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        var carbonModifiers: UInt32 = 0

        if nsModifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if nsModifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if nsModifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if nsModifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }

        ScopyLog.ui.debug("Carbon modifiers: 0x\(String(carbonModifiers, radix: 16), privacy: .public)")

        // 需要至少一个修饰键
        if carbonModifiers != 0 {
            let newKeyCode = UInt32(keyCode)
            let newModifiers = carbonModifiers
            didRecordNewHotKey = true

            ScopyLog.ui.debug(
                "Calling onRecorded callback: keyCode=\(newKeyCode, privacy: .public), modifiers=0x\(String(newModifiers, radix: 16), privacy: .public)"
            )
            onRecorded?(newKeyCode, newModifiers)
            stopRecording(restorePrevious: false)
            return true
        }

        return false
    }

    func stopRecording(restorePrevious: Bool = false) {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        // 未录到新快捷键时恢复原设置
        if restorePrevious,
           !didRecordNewHotKey,
           let previous = previousHotKey {
            ScopyLog.ui.info(
                "Restoring previous hotkey keyCode=\(previous.keyCode, privacy: .public), modifiers=0x\(String(previous.modifiers, radix: 16), privacy: .public)"
            )
            applyHotKeyHandler?(previous.keyCode, previous.modifiers)
        }
    }
}

// MARK: - HotKey Recorder View

/// v0.10: 使用 Environment 注入 AppState，完全解耦
struct HotKeyRecorderView: View {
    @Environment(AppState.self) private var appState

    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @StateObject private var recorder = HotKeyRecorder()

    // 当前显示的快捷键文本
    private var hotkeyText: String {
        return formatHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        HStack {
            Text(recorder.isRecording ? "Press keys..." : hotkeyText)
                .foregroundStyle(recorder.isRecording ? .blue : .primary)
            if recorder.isRecording {
                Image(systemName: "keyboard")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, ScopySpacing.lg)
        .padding(.vertical, ScopySpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: ScopySize.Corner.md)
                .fill(recorder.isRecording ? Color.blue.opacity(ScopySize.Opacity.subtle) : Color.gray.opacity(ScopySize.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScopySize.Corner.md)
                .stroke(recorder.isRecording ? Color.blue : Color.gray.opacity(ScopySize.Opacity.light), lineWidth: ScopySize.Stroke.normal)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            ScopyLog.ui.debug("Tapped: isRecording=\(recorder.isRecording, privacy: .public)")
            if recorder.isRecording {
                recorder.stopRecording(restorePrevious: true)
            } else {
                recorder.startRecording(currentKeyCode: keyCode, currentModifiers: modifiers)
            }
        }
        .onAppear {
            ScopyLog.ui.info("HotKeyRecorderView onAppear: setting up callbacks")

            // 注入回调到 recorder（完全解耦）
            recorder.unregisterHotKeyHandler = appState.unregisterHotKeyHandler
            recorder.applyHotKeyHandler = appState.applyHotKeyHandler

            // 关键：设置回调直接更新 binding，避免 .onChange 时机问题
            recorder.onRecorded = { [weak appState] newKeyCode, newModifiers in
                ScopyLog.ui.debug("onRecorded callback triggered")
                keyCode = newKeyCode
                modifiers = newModifiers
                ScopyLog.ui.debug(
                    "Direct binding update: keyCode=\(newKeyCode, privacy: .public), modifiers=0x\(String(newModifiers, radix: 16), privacy: .public)"
                )

                // 通过注入的回调立即更新全局快捷键（完全解耦）
                Task { @MainActor in
                    ScopyLog.ui.info("Calling applyHotKey via callback")
                    appState?.applyHotKeyHandler?(newKeyCode, newModifiers)
                    ScopyLog.ui.info("Hotkey immediately updated and persisted")
                }
            }
        }
        .onDisappear {
            recorder.stopRecording(restorePrevious: true)
        }
    }

    // 格式化快捷键显示
    private func formatHotKey(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []

        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        // 转换 keyCode 到字符
        let keyChar = keyCharFromKeyCode(keyCode)
        parts.append(keyChar)

        return parts.joined()
    }

    // 从 keyCode 获取显示字符
    private func keyCharFromKeyCode(_ keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
        ]
        return keyMap[keyCode] ?? "?"
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(AppState.shared)
        .environment(AppState.shared.historyViewModel)
        .environment(AppState.shared.settingsViewModel)
}
