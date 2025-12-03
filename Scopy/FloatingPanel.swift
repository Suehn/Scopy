import AppKit
import SwiftUI

/// 窗口定位模式
enum PanelPositionMode {
    case statusBar      // 原有行为：状态栏按钮下方
    case mousePosition  // 新行为：鼠标位置
}

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
        contentView = NSHostingView(
            rootView: view()
                .ignoresSafeArea()
        )
    }

    func toggle(positionMode: PanelPositionMode = .statusBar) {
        if isPresented {
            close()
        } else {
            open(positionMode: positionMode)
        }
    }

    func open(positionMode: PanelPositionMode = .statusBar) {
        var origin: NSPoint

        switch positionMode {
        case .statusBar:
            origin = calculateStatusBarPosition()
        case .mousePosition:
            origin = calculateMousePosition()
        }

        // 应用屏幕边界约束
        origin = constrainToScreen(origin: origin)

        setFrameOrigin(origin)
        orderFrontRegardless()
        makeKey()
        isPresented = true
        statusBarButton?.isHighlighted = true
    }

    // MARK: - Position Calculation

    /// 计算状态栏按钮下方的位置（原有行为）
    private func calculateStatusBarPosition() -> NSPoint {
        guard let button = statusBarButton, let buttonWindow = button.window else {
            return calculateFallbackPosition()
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        return NSPoint(
            x: screenRect.midX - frame.width / 2,
            y: screenRect.minY - frame.height - 4
        )
    }

    /// 计算鼠标位置附近的窗口位置（新行为）
    private func calculateMousePosition() -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let offset: CGFloat = 8

        // 窗口左上角在鼠标位置右下方，避免遮挡光标
        return NSPoint(
            x: mouseLocation.x + offset,
            y: mouseLocation.y - frame.height - offset
        )
    }

    /// 约束窗口位置到屏幕可见区域内
    private func constrainToScreen(origin: NSPoint) -> NSPoint {
        // 找到包含鼠标或窗口的屏幕
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = targetScreen else {
            return origin
        }

        let screenFrame = screen.visibleFrame
        var constrainedOrigin = origin

        // 水平约束
        if constrainedOrigin.x + frame.width > screenFrame.maxX {
            constrainedOrigin.x = screenFrame.maxX - frame.width
        }
        if constrainedOrigin.x < screenFrame.minX {
            constrainedOrigin.x = screenFrame.minX
        }

        // 垂直约束
        if constrainedOrigin.y < screenFrame.minY {
            constrainedOrigin.y = screenFrame.minY
        }
        if constrainedOrigin.y + frame.height > screenFrame.maxY {
            constrainedOrigin.y = screenFrame.maxY - frame.height
        }

        return constrainedOrigin
    }

    /// 兜底位置：屏幕中心
    private func calculateFallbackPosition() -> NSPoint {
        guard let screen = NSScreen.main else {
            return NSPoint(x: 100, y: 100)
        }
        let screenFrame = screen.visibleFrame
        return NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        )
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
