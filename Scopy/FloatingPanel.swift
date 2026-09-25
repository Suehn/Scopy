import AppKit
import SwiftUI

/// Where the panel opens.
enum PanelPositionMode {
    case statusBar
    case mousePosition
}

enum PanelReopenSearchResetPolicy {
    static let staleIntervalSeconds: TimeInterval = 180
}

/// Whether losing key focus should close the history panel.
///
/// "Focus left the panel" normally means the user is done with it. A pinned preview is the one
/// exception: it is Scopy's own window, and clicking or dragging it must not take the history
/// panel down with it.
///
/// The decision is made from the event that caused the key change rather than from the incoming
/// key window, because AppKit installs the new key window only after `resignKey` returns. Waiting
/// a run loop turn for it would reorder the close against the status-item toggle, which reads
/// `isPresented`.
enum FloatingPanelDismissPolicy {
    static func closesOnResignKey(
        eventType: NSEvent.EventType?,
        eventWindow: NSWindow?,
        isPinnedPreviewWindow: (NSWindow) -> Bool
    ) -> Bool {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let eventWindow else { return true }
            return !isPinnedPreviewWindow(eventWindow)
        default:
            return true
        }
    }
}

/// The floating history panel (modelled on Maccy's FloatingPanel).
class FloatingPanel: NSPanel, NSWindowDelegate {
    var isPresented: Bool = false
    var statusBarButton: NSStatusBarButton?
    private(set) var lastClosedAt: Date?
    /// Runs after every close, whatever triggered it (toggle, copy, focus loss).
    var onClose: (() -> Void)?

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
        // Remembers the size the user resized to; the origin is recomputed on every open.
        setFrameAutosaveName("ScopyHistoryPanel")

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

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

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
        // A size remembered on a larger display must still fit the display it opens on.
        if let visibleFrame = targetScreen()?.visibleFrame {
            let fitted = NSSize(
                width: min(frame.width, visibleFrame.width),
                height: min(frame.height, visibleFrame.height)
            )
            if fitted != frame.size {
                setFrame(NSRect(origin: frame.origin, size: fitted), display: false)
            }
        }

        var origin: NSPoint

        switch positionMode {
        case .statusBar:
            origin = calculateStatusBarPosition()
        case .mousePosition:
            origin = calculateMousePosition()
        }

        origin = constrainToScreen(origin: origin)

        setFrameOrigin(origin)
        orderFrontRegardless()
        makeKey()
        isPresented = true
        lastClosedAt = nil
        statusBarButton?.isHighlighted = true
    }

    func wasClosedLongerThan(_ interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastClosedAt else { return false }
        return now.timeIntervalSince(lastClosedAt) > interval
    }

    // MARK: - Position Calculation

    /// Below the status-item button.
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

    /// Next to the mouse pointer.
    private func calculateMousePosition() -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let offset: CGFloat = 8

        // The top-left corner sits below and right of the pointer so the panel does not cover it.
        return NSPoint(
            x: mouseLocation.x + offset,
            y: mouseLocation.y - frame.height - offset
        )
    }

    /// Keeps the panel inside the screen's visible frame.
    /// The screen under the pointer, where the panel opens.
    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func constrainToScreen(origin: NSPoint) -> NSPoint {
        guard let screen = targetScreen() else {
            return origin
        }

        let screenFrame = screen.visibleFrame
        var constrainedOrigin = origin

        if constrainedOrigin.x + frame.width > screenFrame.maxX {
            constrainedOrigin.x = screenFrame.maxX - frame.width
        }
        if constrainedOrigin.x < screenFrame.minX {
            constrainedOrigin.x = screenFrame.minX
        }

        if constrainedOrigin.y < screenFrame.minY {
            constrainedOrigin.y = screenFrame.minY
        }
        if constrainedOrigin.y + frame.height > screenFrame.maxY {
            constrainedOrigin.y = screenFrame.maxY - frame.height
        }

        return constrainedOrigin
    }

    /// Fallback: the center of the main screen.
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
        lastClosedAt = Date()
        statusBarButton?.isHighlighted = false
        onClose?()
    }

    override func resignKey() {
        super.resignKey()
        let causingEvent = NSApp.currentEvent
        guard FloatingPanelDismissPolicy.closesOnResignKey(
            eventType: causingEvent?.type,
            eventWindow: causingEvent?.window,
            isPinnedPreviewWindow: { $0 is PinnedPreviewPanel }
        ) else { return }
        close()
    }

    override var canBecomeKey: Bool {
        return true
    }
}
