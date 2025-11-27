import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    private var hotKeyService: HotKeyService?
    private var settingsWindow: NSWindow?

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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
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

        // 启动后端服务
        Task {
            await AppState.shared.start()
        }

        // 注册全局快捷键 ⇧⌘C
        hotKeyService = HotKeyService()
        hotKeyService?.register { [weak self] in
            self?.togglePanel()
        }

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

    @objc private func togglePanel() {
        panel?.toggle()
    }

    // MARK: - Settings Window

    /// 打开设置窗口
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
            window.contentView = NSHostingView(rootView: settingsView)
            window.center()

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
