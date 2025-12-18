import AppKit
import ScopyKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 单例访问
    static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    var panel: FloatingPanel?
    private var uiTestWindow: NSWindow?
    private(set) var hotKeyService: HotKeyService?
    private var settingsWindow: NSWindow?
    private var appliedHotKey: (keyCode: UInt32, modifiers: UInt32)?
    private var isHotKeyRegistered = false
    private let settingsStore: SettingsStore = .shared
    /// v0.22: 存储事件监视器引用，以便在应用退出时移除
    private var localEventMonitor: Any?

    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Scopy")
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        return statusItem
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appState = AppState.shared

        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let isExportHarness: Bool = {
#if DEBUG
            return isUITesting && ProcessInfo.processInfo.environment["SCOPY_UITEST_EXPORT_HARNESS"] == "1"
#else
            return false
#endif
        }()

        let rootView: AnyView = {
#if DEBUG
            if isExportHarness {
                return AnyView(
                    ExportPreviewHarnessView()
                        .environment(appState)
                        .environment(appState.historyViewModel)
                        .environment(appState.settingsViewModel)
                )
            }
#endif
            return AnyView(
                ContentView()
                    .environment(appState)
                    .environment(appState.historyViewModel)
                    .environment(appState.settingsViewModel)
            )
        }()

        if isUITesting {
            // XCUITest interacts more reliably with a standard window than a non-activating panel.
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: Int(ScopySize.Window.mainWidth),
                    height: Int(ScopySize.Window.mainHeight)
                ),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Scopy"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isReleasedWhenClosed = false
            // Keep the test window on top to avoid other apps occluding it and causing hit-testing failures.
            window.level = .floating
            window.center()
            window.contentView = NSHostingView(rootView: rootView)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            uiTestWindow = window
        } else {
            // 创建浮动面板
            panel = FloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: Int(ScopySize.Window.mainWidth), height: Int(ScopySize.Window.mainHeight)),
                statusBarButton: statusItem.button
            ) {
                rootView
            }
        }

        // 显示状态栏图标
        _ = statusItem

        // 设置 UI 回调
        appState.closePanelHandler = { [weak self] in
            if isUITesting {
                self?.uiTestWindow?.close()
            } else {
                self?.panel?.close()
            }
        }
        appState.openSettingsHandler = { [weak self] in
            self?.openSettings()
        }

        // 设置快捷键回调（用于解耦 SettingsView 与 AppDelegate）
        appState.applyHotKeyHandler = { [weak self] keyCode, modifiers in
            self?.applyHotKey(keyCode: keyCode, modifiers: modifiers)
        }
        appState.unregisterHotKeyHandler = { [weak self] in
            self?.hotKeyService?.unregister()
            self?.isHotKeyRegistered = false
        }

        // 启动后端服务
        Task {
            await appState.start()
        }

        #if DEBUG
        if isUITesting, ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] == "1" {
            Task { @MainActor in
                await self.runUITestAutoExportMarkdown()
            }
        }
        #endif

        // 注册全局快捷键（从设置加载或使用默认 ⇧⌘C）
        hotKeyService = HotKeyService()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await settingsStore.load()
            applyHotKey(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        }

        // 注册 ⌘, 快捷键打开设置
        // v0.22: 存储监视器引用，以便在应用退出时移除
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌥⌫ (Option+Delete) - 删除选中项
            // NOTE: SwiftUI TextField may consume ⌥⌫ for word deletion; handle at the AppKit layer so the shortcut always works.
            if flags.contains(.option),
               !flags.contains(.command),
               !flags.contains(.control),
               !flags.contains(.shift),
               (event.keyCode == 51 || event.keyCode == 117),
               (self.panel?.isVisible == true || self.uiTestWindow?.isVisible == true),
               AppState.shared.historyViewModel.selectedID != nil {
                Task { @MainActor in
                    await AppState.shared.historyViewModel.deleteSelectedItem()
                }
                return nil
            }

            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers == "," {
                self.openSettings()
                return nil
            }
            return event
        }

        if isUITesting {
            // Window already presented above.
        }
    }

    // MARK: - UI Testing

    #if DEBUG
    @MainActor
    private func runUITestAutoExportMarkdown() async {
        let processInfo = ProcessInfo.processInfo
        let dumpPath = processInfo.environment["SCOPY_EXPORT_DUMP_PATH"] ?? ""
        let errorPath = processInfo.environment["SCOPY_EXPORT_ERROR_DUMP_PATH"] ?? ""

        let containerWidthPoints: CGFloat = {
            if let s = processInfo.environment["SCOPY_EXPORT_CONTAINER_WIDTH_POINTS"],
               let d = Double(s),
               d > 0 {
                return CGFloat(d)
            }
            return 820
        }()

        func writeError(_ message: String) {
            guard !errorPath.isEmpty else { return }
            try? Data(message.utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
        }

        guard let markdownPath = processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"],
              !markdownPath.isEmpty
        else {
            writeError("Missing SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH")
            return
        }

        guard let markdown = try? String(contentsOfFile: markdownPath, encoding: .utf8), !markdown.isEmpty else {
            writeError("Failed to read markdown from \(markdownPath)")
            return
        }

        do {
            let html = MarkdownHTMLRenderer.render(markdown: markdown)
            let renderer = MarkdownExportRenderer()
            let pngData = try await renderer.renderPNG(
                html: html,
                containerWidthPoints: containerWidthPoints,
                maxShortSidePixels: 1500,
                maxLongSidePixels: 16_384 * 4
            )
            if !dumpPath.isEmpty {
                try pngData.write(to: URL(fileURLWithPath: dumpPath), options: [.atomic])
            }
        } catch {
            writeError(String(describing: error))
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 清理资源
        hotKeyService?.unregister()
        isHotKeyRegistered = false
        // v0.22: 移除事件监视器，防止内存泄漏
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        AppState.shared.stop()
    }

    @objc func togglePanel() {
        // 状态栏点击：窗口在状态栏下方
        if let panel {
            panel.toggle(positionMode: .statusBar)
        } else if let uiTestWindow {
            if uiTestWindow.isVisible {
                uiTestWindow.close()
            } else {
                uiTestWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func togglePanelAtMousePosition() {
        // 快捷键触发：窗口在鼠标位置
        if let panel {
            panel.toggle(positionMode: .mousePosition)
        } else {
            togglePanel()
        }
    }

    // MARK: - Hotkey Settings

    /// 统一应用并持久化快捷键，确保无需重启即可生效
    @MainActor
    func applyHotKey(keyCode: UInt32, modifiers: UInt32) {
        let requested = (keyCode: keyCode, modifiers: modifiers)

        if hotKeyService?.isRegistered == true,
           let applied = appliedHotKey,
           applied.keyCode == requested.keyCode,
           applied.modifiers == requested.modifiers {
            return
        }

        if hotKeyService == nil {
            hotKeyService = HotKeyService()
        }

        let previousHotKey = appliedHotKey

        hotKeyService?.updateHotKey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: { [weak self] in
                self?.togglePanelAtMousePosition()
            }
        )

        guard hotKeyService?.isRegistered == true else {
            ScopyLog.hotkey.error(
                "Failed to register global hotkey, reverting. keyCode=\(keyCode, privacy: .public), modifiers=0x\(String(modifiers, radix: 16), privacy: .public)"
            )

            let fallback = previousHotKey ?? (SettingsDTO.default.hotkeyKeyCode, SettingsDTO.default.hotkeyModifiers)
            hotKeyService?.updateHotKey(
                keyCode: fallback.0,
                modifiers: fallback.1,
                handler: { [weak self] in
                    self?.togglePanelAtMousePosition()
                }
            )

            if hotKeyService?.isRegistered == true {
                appliedHotKey = (fallback.0, fallback.1)
                isHotKeyRegistered = true
                persistHotkeySettings(keyCode: fallback.0, modifiers: fallback.1)
            } else {
                appliedHotKey = nil
                isHotKeyRegistered = false
            }
            return
        }

        appliedHotKey = requested
        isHotKeyRegistered = true
        persistHotkeySettings(keyCode: requested.keyCode, modifiers: requested.modifiers)
    }

    private func persistHotkeySettings(keyCode: UInt32, modifiers: UInt32) {
        let settingsStore = settingsStore
        Task {
            await settingsStore.updateHotkey(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Settings Window

    /// 打开设置窗口
    /// v0.10: 注入 AppState 到 Environment，实现完全解耦
    /// v0.17: 修复内存泄漏 - 窗口关闭时释放并清空引用
    @MainActor
    func openSettings() {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: Int(ScopySize.Window.settingsWidth),
                    height: Int(ScopySize.Window.settingsHeight)
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Scopy Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: ScopySize.Window.settingsWidth, height: ScopySize.Window.settingsHeight)
            window.minSize = NSSize(width: ScopySize.Window.settingsWidth, height: ScopySize.Window.settingsHeight)
            window.delegate = self
            window.center()

            settingsWindow = window
        }

        window.contentView = NSHostingView(rootView: makeSettingsView(onDismiss: { [weak self] in
            self?.dismissSettings()
        }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == settingsWindow {
            dismissSettings()
            return false
        }
        return true
    }

    private func dismissSettings() {
        settingsWindow?.orderOut(nil)
    }

    private func makeSettingsView(onDismiss: @escaping () -> Void) -> some View {
        SettingsView(onDismiss: onDismiss)
            .environment(AppState.shared)
            .environment(AppState.shared.historyViewModel)
            .environment(AppState.shared.settingsViewModel)
    }
}

#if DEBUG
/// UI testing harness: shows the real Markdown preview view (including export buttons) inside a stable window.
@MainActor
private struct ExportPreviewHarnessView: View {
    @StateObject private var model: HoverPreviewModel
    private let controller = MarkdownPreviewWebViewController()

    init() {
        let markdown = Self.loadMarkdown()
        let m = HoverPreviewModel()
        m.text = markdown
        m.isMarkdown = true
        m.markdownHTML = MarkdownHTMLRenderer.render(markdown: markdown)
        _model = StateObject(wrappedValue: m)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HistoryItemTextPreviewView(model: model, markdownWebViewController: controller)
                .padding(12)

            Text("Export Harness")
                .opacity(0.001)
                .accessibilityIdentifier("UITest.ExportPreviewHarness")
        }
        .frame(minWidth: 820, minHeight: 620)
        .accessibilityIdentifier("UITest.ExportPreviewHarness.Root")
    }

    private static func loadMarkdown() -> String {
        if let path = ProcessInfo.processInfo.environment["SCOPY_UITEST_EXPORT_MARKDOWN_PATH"],
           !path.isEmpty,
           let s = try? String(contentsOfFile: path, encoding: .utf8),
           !s.isEmpty {
            return s
        }

        return """
        # SCOPY_UITEST_EXPORT_HARNESS

        ## Wide Table

        | very_long_header_col_01 | very_long_header_col_02 | very_long_header_col_03 | very_long_header_col_04 | very_long_header_col_05 |
        | --- | --- | --- | --- | --- |
        | 1 | 2 | 3 | 4 | 5 |
        | aaaaaaaaaaaaaaaaaaaaa | bbbbbbbbbbbbbbbbbbbbb | ccccccccccccccccccccc | ddddddddddddddddddddd | eeeeeeeeeeeeeeeeeeeee |
        """
    }
}
#endif
