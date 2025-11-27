import SwiftUI
import Carbon.HIToolbox

/// 设置窗口视图
/// v0.6: 多页 TabView 结构，支持快捷键自定义、搜索模式选择、存储统计
struct SettingsView: View {
    @State private var selectedTab = 0
    @State private var tempSettings: SettingsDTO
    @State private var isSaving = false
    @State private var storageStats: StorageStatsDTO?
    @State private var isLoadingStats = false

    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        _tempSettings = State(initialValue: AppState.shared.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                GeneralSettingsTab(
                    tempSettings: $tempSettings
                )
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

                StorageSettingsTab(
                    tempSettings: $tempSettings,
                    storageStats: storageStats,
                    isLoading: isLoadingStats,
                    onRefresh: refreshStats
                )
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }
                .tag(1)

                AboutTab()
                    .tabItem {
                        Label("About", systemImage: "info.circle")
                    }
                    .tag(2)
            }
            .padding(.top, 10)

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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 500, height: 420)
        .onAppear {
            tempSettings = AppState.shared.settings
            refreshStats()
        }
    }

    private func refreshStats() {
        isLoadingStats = true
        Task {
            do {
                storageStats = try await AppState.shared.service.getDetailedStorageStats()
            } catch {
                print("Failed to load storage stats: \(error)")
            }
            isLoadingStats = false
        }
    }

    private func saveSettings() {
        isSaving = true

        print("🔧 saveSettings: keyCode=\(tempSettings.hotkeyKeyCode), modifiers=0x\(String(tempSettings.hotkeyModifiers, radix: 16))")

        Task {
            await AppState.shared.updateSettings(tempSettings)
            // 更新 AppState 的搜索模式
            await MainActor.run {
                AppState.shared.searchMode = tempSettings.defaultSearchMode

                // 立即更新全局快捷键
                print("🔧 Updating hotkey service")
                AppDelegate.shared?.applyHotKey(
                    keyCode: tempSettings.hotkeyKeyCode,
                    modifiers: tempSettings.hotkeyModifiers
                )

                isSaving = false
                onDismiss?()
            }
        }
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
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

            // MARK: - Search Section
            Section {
                Picker("Default Search Mode", selection: $tempSettings.defaultSearchMode) {
                    Text("Exact").tag(SearchMode.exact)
                    Text("Fuzzy").tag(SearchMode.fuzzy)
                    Text("Regex").tag(SearchMode.regex)
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Search", systemImage: "magnifyingglass")
            } footer: {
                Text("Exact=精确 | Fuzzy=模糊(推荐) | Regex=正则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Content Types Section
            Section {
                Toggle("Save Images", isOn: $tempSettings.saveImages)
                Toggle("Save Files", isOn: $tempSettings.saveFiles)
            } header: {
                Label("Content Types", systemImage: "doc.on.clipboard")
            } footer: {
                Text("Disable to skip saving specific content types to history.")
                    .foregroundStyle(.secondary)
            }

            // MARK: - Image Thumbnails Section (v0.8)
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
                        .frame(width: 100)
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
                        .frame(width: 100)
                    }
                }
            } header: {
                Label("Image Thumbnails", systemImage: "photo")
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
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Show in Finder") {
                    let path = storageStats?.databasePath ?? "~/Library/Application Support/Scopy/"
                    let expandedPath = NSString(string: path).expandingTildeInPath
                    let url = URL(fileURLWithPath: expandedPath)

                    if FileManager.default.fileExists(atPath: expandedPath) {
                        // 选中文件并打开 Finder
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        // 文件不存在时，打开父目录
                        let parentURL = url.deletingLastPathComponent()
                        NSWorkspace.shared.activateFileViewerSelecting([parentURL])
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

struct AboutTab: View {
    @State private var performanceSummary: PerformanceSummary?
    @State private var memoryUsageMB: Double = 0
    @State private var autoRefreshTimer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            // App Icon and Version
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Scopy")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version \(AppVersion.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            Divider()
                .padding(.horizontal, 32)

            // Features - 紧凑两列布局
            GroupBox {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
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
            .padding(.horizontal, 20)

            // Performance - GroupBox 样式
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    // Search
                    HStack(alignment: .firstTextBaseline) {
                        Text("Search")
                            .font(.caption)
                            .frame(width: 50, alignment: .leading)
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
                            .frame(width: 50, alignment: .leading)
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
                            .frame(width: 50, alignment: .leading)
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
            .padding(.horizontal, 20)

            Spacer()

            // Links
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com")!)
                Link("Report Issue", destination: URL(string: "https://github.com")!)
            }
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.bottom, 8)
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

    private func startAutoRefresh() {
        // 30 分钟自动刷新
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            refreshPerformance()
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
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
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - HotKey Recorder (ObservableObject)

/// 快捷键录制器 - 使用 class 以便在闭包中正确更新状态
/// v0.9.3: 使用回调方式直接更新 binding，避免 .onChange 时机问题
class HotKeyRecorder: ObservableObject {
    @Published var isRecording = false

    /// 录制完成回调 - 直接更新 binding
    var onRecorded: ((UInt32, UInt32) -> Void)?

    private var eventMonitor: Any?
    private var globalEventMonitor: Any?
    private var previousHotKey: (keyCode: UInt32, modifiers: UInt32)?
    private var didRecordNewHotKey = false

    func startRecording(currentKeyCode: UInt32, currentModifiers: UInt32) {
        guard !isRecording else { return }

        isRecording = true
        didRecordNewHotKey = false
        previousHotKey = (currentKeyCode, currentModifiers)
        print("🎹 Started hotkey recording")

        // 暂停当前全局热键，避免录制同一组合时被 Carbon 拦截
        AppDelegate.shared?.hotKeyService?.unregister()

        // 尝试前置窗口，减少焦点问题；全局监听兜底
        NSApp.activate(ignoringOtherApps: true)

        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard let self = self else { return false }
            return self.handleKeyEvent(event)
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handler(event) ? nil : event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            _ = handler(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        print("🎹 Key pressed: keyCode=\(event.keyCode), modifiers=\(event.modifierFlags.rawValue)")

        // ESC 取消录制并恢复原快捷键
        if event.keyCode == 53 {
            print("🎹 ESC pressed, cancelling recording")
            DispatchQueue.main.async {
                self.stopRecording(restorePrevious: true)
            }
            return true
        }

        // 获取修饰键（转换为 Carbon 格式）
        let nsModifiers = event.modifierFlags
        var carbonModifiers: UInt32 = 0

        if nsModifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if nsModifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if nsModifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if nsModifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }

        print("🎹 Carbon modifiers: 0x\(String(carbonModifiers, radix: 16))")

        // 需要至少一个修饰键
        if carbonModifiers != 0 {
            let newKeyCode = UInt32(event.keyCode)
            let newModifiers = carbonModifiers
            didRecordNewHotKey = true

            DispatchQueue.main.async {
                print("🎹 Calling onRecorded callback: keyCode=\(newKeyCode), modifiers=0x\(String(newModifiers, radix: 16))")
                self.onRecorded?(newKeyCode, newModifiers)
                self.stopRecording(restorePrevious: false)
            }
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
            print("🎹 Restoring previous hotkey keyCode=\(previous.keyCode), modifiers=0x\(String(previous.modifiers, radix: 16))")
            Task { @MainActor in
                AppDelegate.shared?.applyHotKey(
                    keyCode: previous.keyCode,
                    modifiers: previous.modifiers
                )
            }
        }
    }
}

// MARK: - HotKey Recorder View

struct HotKeyRecorderView: View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(recorder.isRecording ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(recorder.isRecording ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            print("🎹 Tapped! isRecording=\(recorder.isRecording)")
            if recorder.isRecording {
                recorder.stopRecording(restorePrevious: true)
            } else {
                recorder.startRecording(currentKeyCode: keyCode, currentModifiers: modifiers)
            }
        }
        .onAppear {
            print("🎹 HotKeyRecorderView onAppear - setting up callback")
            print("🎹 AppDelegate.shared = \(String(describing: AppDelegate.shared))")
            print("🎹 hotKeyService = \(String(describing: AppDelegate.shared?.hotKeyService))")

            // 关键：设置回调直接更新 binding，避免 .onChange 时机问题
            recorder.onRecorded = { newKeyCode, newModifiers in
                print("🎹 onRecorded callback triggered!")
                keyCode = newKeyCode
                modifiers = newModifiers
                print("🎹 Direct binding update: keyCode=\(newKeyCode), modifiers=0x\(String(newModifiers, radix: 16))")

                // 立即更新全局快捷键（无需等待 Save）
                Task { @MainActor in
                    if AppDelegate.shared != nil {
                        print("🎹 Calling applyHotKey on AppDelegate")
                        AppDelegate.shared?.applyHotKey(
                            keyCode: newKeyCode,
                            modifiers: newModifiers
                        )
                        print("🎹 Hotkey immediately updated and persisted!")
                    } else {
                        print("🎹 ERROR: AppDelegate.shared is nil!")
                    }
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
}
