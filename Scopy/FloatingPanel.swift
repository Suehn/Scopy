import AppKit
import SwiftUI

/// 浮动面板 - 参考 Maccy 的 FloatingPanel 实现
class FloatingPanel: NSPanel, NSWindowDelegate {
    var isPresented: Bool = false
    var statusBarButton: NSStatusBarButton?

    init<Content: View>(
        contentRect: NSRect,
        statusBarButton: NSStatusBarButton? = nil,
        @ViewBuilder view: () -> Content
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.statusBarButton = statusBarButton
        delegate = self

        // 面板配置
        animationBehavior = .none
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        titlebarSeparatorStyle = .none

        // 隐藏窗口按钮
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // 设置内容视图
        // v0.10.1: 注入 AppState 到环境，与 SettingsView 保持一致
        contentView = NSHostingView(
            rootView: view()
                .environment(AppState.shared)
                .ignoresSafeArea()
        )
    }

    func toggle() {
        if isPresented {
            close()
        } else {
            open()
        }
    }

    func open() {
        // 计算位置（在状态栏图标下方）
        if let button = statusBarButton, let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)

            var origin = NSPoint(
                x: screenRect.midX - frame.width / 2,
                y: screenRect.minY - frame.height - 4
            )

            // 确保不超出屏幕边界
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - frame.width))
                origin.y = max(screenFrame.minY, origin.y)
            }

            setFrameOrigin(origin)
        }

        orderFrontRegardless()
        makeKey()
        isPresented = true
        statusBarButton?.isHighlighted = true
    }

    override func close() {
        super.close()
        isPresented = false
        statusBarButton?.isHighlighted = false
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override var canBecomeKey: Bool {
        return true
    }
}
