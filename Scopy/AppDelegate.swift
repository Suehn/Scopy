import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    /// 单例访问
    static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    var panel: FloatingPanel?
    private(set) var hotKeyService: HotKeyService?
    private var settingsWindow: NSWindow?
    private let settingsKey = "ScopySettings"

    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Scopy")
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        return statusItem
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建浮动面板
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Int(ScopySize.Window.mainWidth), height: Int(ScopySize.Window.mainHeight)),
            statusBarButton: statusItem.button
        ) {
            ContentView()
        }

        // 显示状态栏图标
        _ = statusItem

        // 设置 UI 回调
        AppState.shared.closePanelHandler = { [weak self] in
            self?.panel?.close()
        }
        AppState.shared.openSettingsHandler = { [weak self] in
            self?.openSettings()
        }

        // 设置快捷键回调（用于解耦 SettingsView 与 AppDelegate）
        AppState.shared.applyHotKeyHandler = { [weak self] keyCode, modifiers in
            self?.applyHotKey(keyCode: keyCode, modifiers: modifiers)
        }
        AppState.shared.unregisterHotKeyHandler = { [weak self] in
            self?.hotKeyService?.unregister()
        }

        // 启动后端服务
        Task {
            await AppState.shared.start()
        }

        // 注册全局快捷键（从设置加载或使用默认 ⇧⌘C）
        hotKeyService = HotKeyService()
        let settings = loadHotkeySettings()
        applyHotKey(keyCode: settings.keyCode, modifiers: settings.modifiers)

        // 注册 ⌘, 快捷键打开设置
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 清理资源
        hotKeyService?.unregister()
        AppState.shared.stop()
    }

    @objc func togglePanel() {
        panel?.toggle()
    }

    // MARK: - Hotkey Settings

    /// 从 UserDefaults 加载快捷键设置
    private func loadHotkeySettings() -> (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: settingsKey) else {
            // 默认: ⇧⌘C (shiftKey | cmdKey, kVK_ANSI_C)
            // shiftKey = 0x0200, cmdKey = 0x0100, 合计 0x0300
            return (8, 0x0300)
        }
        let keyCode = (dict["hotkeyKeyCode"] as? NSNumber)?.uint32Value ?? 8
        let modifiers = (dict["hotkeyModifiers"] as? NSNumber)?.uint32Value ?? 0x0300
        return (keyCode, modifiers)
    }

    /// 统一应用并持久化快捷键，确保无需重启即可生效
    @MainActor
    func applyHotKey(keyCode: UInt32, modifiers: UInt32) {
        if hotKeyService == nil {
            hotKeyService = HotKeyService()
        }

        hotKeyService?.updateHotKey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: { [weak self] in
                self?.togglePanel()
            }
        )
        persistHotkeySettings(keyCode: keyCode, modifiers: modifiers)
    }

    private func persistHotkeySettings(keyCode: UInt32, modifiers: UInt32) {
        var dict = UserDefaults.standard.dictionary(forKey: settingsKey) ?? [:]
        dict["hotkeyKeyCode"] = keyCode
        dict["hotkeyModifiers"] = modifiers
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    // MARK: - Settings Window

    /// 打开设置窗口
    /// v0.10: 注入 AppState 到 Environment，实现完全解耦
    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Scopy Settings"
            window.isReleasedWhenClosed = false

            let settingsView = SettingsView { [weak self] in
                self?.settingsWindow?.close()
            }
            .environment(AppState.shared)  // 注入 AppState 到环境

            window.contentView = NSHostingView(rootView: settingsView)
            window.center()

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
