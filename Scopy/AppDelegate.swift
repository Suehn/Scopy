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
    private(set) var hotKeyService: HotKeyService?
    private var settingsWindow: NSWindow?
    private var settingsWindowCloseObserver: Any?
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

        // 创建浮动面板
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Int(ScopySize.Window.mainWidth), height: Int(ScopySize.Window.mainHeight)),
            statusBarButton: statusItem.button
        ) {
            ContentView()
                .environment(appState)
                .environment(appState.historyViewModel)
                .environment(appState.settingsViewModel)
        }

        // 显示状态栏图标
        _ = statusItem

        // 设置 UI 回调
        appState.closePanelHandler = { [weak self] in
            self?.panel?.close()
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
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers == "," {
                self?.openSettings()
                return nil
            }
            return event
        }

        if isUITesting {
            openSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 清理资源
        hotKeyService?.unregister()
        isHotKeyRegistered = false
        if let observer = settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsWindowCloseObserver = nil
        }
        // v0.22: 移除事件监视器，防止内存泄漏
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        AppState.shared.stop()
    }

    @objc func togglePanel() {
        // 状态栏点击：窗口在状态栏下方
        panel?.toggle(positionMode: .statusBar)
    }

    func togglePanelAtMousePosition() {
        // 快捷键触发：窗口在鼠标位置
        panel?.toggle(positionMode: .mousePosition)
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
        if settingsWindow == nil {
            let window = NSWindow(
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
            window.isReleasedWhenClosed = true  // v0.17: 关闭时释放窗口

            let settingsView = SettingsView { [weak self] in
                self?.settingsWindow?.close()
            }
            .environment(AppState.shared)
            .environment(AppState.shared.historyViewModel)
            .environment(AppState.shared.settingsViewModel)

            window.contentView = NSHostingView(rootView: settingsView)
            window.center()

            // v0.17: 监听窗口关闭事件，清空引用避免悬空指针
            settingsWindowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let observer = self.settingsWindowCloseObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.settingsWindowCloseObserver = nil
                    }
                    self.settingsWindow = nil
                }
            }

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
