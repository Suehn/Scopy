import AppKit
import CoreGraphics

enum HoverPreviewScreenMetrics {
    static func activeVisibleFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? .zero
    }

    static func maxPopoverWidthPoints() -> CGFloat {
        let visibleWidth = activeVisibleFrame().width
        if visibleWidth > 0 {
            // Popover is anchored to list items on the right; keep enough space to avoid going off-screen.
            return min(ScopySize.Width.previewMax, floor(visibleWidth * 0.62))
        }
        return ScopySize.Width.previewMax
    }

    static func maxPopoverHeightPoints() -> CGFloat {
        let visibleHeight = activeVisibleFrame().height
        if visibleHeight > 0 {
            return floor(visibleHeight * 0.70)
        }
        return ScopySize.Window.mainHeight
    }
}
