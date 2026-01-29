import AppKit
import ScopyKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// 单例访问
    static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    var panel: FloatingPanel?
    private var uiTestWindow: NSWindow?
    private(set) var hotKeyService: HotKeyService?
    private lazy var settingsWindowCoordinator = SettingsWindowCoordinator()
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
        let context = resolveLaunchContext()

        if context.isExportHarness {
            uiTestWindow = makeExportHarnessWindow()
            return
        }

        let appState = AppState.shared
        let rootView = makeRootView(appState: appState)

        if context.isUITesting {
            uiTestWindow = makeUITestWindow(rootView: rootView)
        } else {
            panel = makeMainPanel(rootView: rootView)
        }

        // 显示状态栏图标
        _ = statusItem

        configureAppHandlers(appState: appState, isUITesting: context.isUITesting)

        // 启动后端服务
        Task {
            await appState.start()
        }

        if context.isUITesting, ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] == "1" {
            Task { @MainActor in
                await self.runUITestAutoExportMarkdown(appState: appState)
            }
        }

        setupHotKeyRegistration()
        installLocalEventMonitor()
    }

    private struct LaunchContext {
        let isUITesting: Bool
        let isExportHarness: Bool
    }

    private func resolveLaunchContext() -> LaunchContext {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let isExportHarness = isUITesting && ProcessInfo.processInfo.environment["SCOPY_UITEST_EXPORT_HARNESS"] == "1"
        return LaunchContext(isUITesting: isUITesting, isExportHarness: isExportHarness)
    }

    private func makeRootView(appState: AppState) -> some View {
        ContentView()
            .environment(appState)
            .environment(appState.historyViewModel)
            .environment(appState.settingsViewModel)
    }

    private func makeExportHarnessWindow() -> NSWindow {
        let window = makeHostingWindow(
            rootView: ExportPreviewHarnessView(),
            size: NSSize(width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            title: "Scopy Export Harness",
            level: .floating
        )
        return window
    }

    private func makeUITestWindow<V: View>(rootView: V) -> NSWindow {
        let window = makeHostingWindow(
            rootView: rootView,
            size: NSSize(width: ScopySize.Window.mainWidth, height: ScopySize.Window.mainHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            title: "Scopy",
            level: .floating
        )
        return window
    }

    private func makeMainPanel<V: View>(rootView: V) -> FloatingPanel {
        FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Int(ScopySize.Window.mainWidth), height: Int(ScopySize.Window.mainHeight)),
            statusBarButton: statusItem.button
        ) {
            rootView
        }
    }

    private func makeHostingWindow<V: View>(
        rootView: V,
        size: NSSize,
        styleMask: NSWindow.StyleMask,
        title: String,
        level: NSWindow.Level? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        if let level {
            window.level = level
        }
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func configureAppHandlers(appState: AppState, isUITesting: Bool) {
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
    }

    private func setupHotKeyRegistration() {
        // 注册全局快捷键（从设置加载或使用默认 ⇧⌘C）
        hotKeyService = HotKeyService()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await settingsStore.load()
            applyHotKey(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        }
    }

    private func installLocalEventMonitor() {
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
    }

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

    // MARK: - UI Testing

    @MainActor
    private func runUITestAutoExportMarkdown(appState: AppState) async {
        let dumpPath = ProcessInfo.processInfo.environment["SCOPY_EXPORT_DUMP_PATH"] ?? ""
        let errorPath = ProcessInfo.processInfo.environment["SCOPY_EXPORT_ERROR_DUMP_PATH"] ?? ""

        if let markdownPath = ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"],
           !markdownPath.isEmpty,
           let markdown = try? String(contentsOfFile: markdownPath, encoding: .utf8),
           !markdown.isEmpty {
            let html = MarkdownHTMLRenderer.render(markdown: markdown)
            MarkdownExportService.exportToPNGClipboard(html: html, targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels) { result in
                if case .failure(let error) = result, !errorPath.isEmpty {
                    try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
                } else if case .success = result, !dumpPath.isEmpty {
                    // exportToPNGClipboard already writes the dump; nothing else needed.
                }
            }
            return
        }

        if let htmlPath = ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"],
           !htmlPath.isEmpty,
           let html = try? String(contentsOfFile: htmlPath, encoding: .utf8),
           !html.isEmpty {
            MarkdownExportService.exportToPNGClipboard(html: html, targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels) { result in
                if case .failure(let error) = result, !errorPath.isEmpty {
                    try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
                } else if case .success = result, !dumpPath.isEmpty {
                    // exportToPNGClipboard already writes the dump; nothing else needed.
                }
            }
            return
        }

        // Wait for history to load.
        for _ in 0..<200 {
            if !appState.historyViewModel.items.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let item = appState.historyViewModel.items.first(where: { $0.plainText.contains("SCOPY_EXPORT_TEST_MARKDOWN") }) else {
            if !errorPath.isEmpty {
                try? Data("Missing SCOPY_EXPORT_TEST_MARKDOWN fixture".utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
            }
            return
        }

        let html = MarkdownHTMLRenderer.render(markdown: item.plainText)

        MarkdownExportService.exportToPNGClipboard(html: html, targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels) { result in
            if case .failure(let error) = result, !errorPath.isEmpty {
                try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
            } else if case .success = result, !dumpPath.isEmpty {
                // exportToPNGClipboard already writes the dump; nothing else needed.
            }
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
        settingsWindowCoordinator.show()
    }
}
