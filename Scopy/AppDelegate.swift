import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    private var hotKeyService: HotKeyService?

    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Scopy")
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        return statusItem
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 连接 AppState
        AppState.shared.appDelegate = self

        // 创建浮动面板
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            statusBarButton: statusItem.button
        ) {
            ContentView()
        }

        // 显示状态栏图标
        _ = statusItem

        // 启动后端服务
        Task {
            await AppState.shared.start()
        }

        // 注册全局快捷键 ⇧⌘C
        hotKeyService = HotKeyService()
        hotKeyService?.register { [weak self] in
            self?.togglePanel()
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
}
