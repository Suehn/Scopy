import AppKit
import SwiftUI

/// 管理 Settings 窗口的创建/复用/关闭行为。
///
/// 约束：保持用户无感（仍然是 “关闭按钮 = 隐藏窗口”，Settings 内部仍然是 Save/Cancel 事务模型）。
@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let window = ensureWindow()
        window.contentView = NSHostingView(
            rootView: makeSettingsView(onDismiss: { [weak self] in
                Task { @MainActor in
                    self?.dismiss()
                }
            })
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            dismiss()
            return false
        }
        return true
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

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
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: ScopySize.Window.settingsWidth, height: ScopySize.Window.settingsHeight)
        window.minSize = NSSize(width: ScopySize.Window.settingsWidth, height: ScopySize.Window.settingsHeight)
        window.delegate = self
        window.center()

        self.window = window
        return window
    }

    private func makeSettingsView(onDismiss: @escaping () -> Void) -> some View {
        SettingsView(onDismiss: onDismiss)
            .environment(AppState.shared)
            .environment(AppState.shared.historyViewModel)
            .environment(AppState.shared.settingsViewModel)
    }
}

