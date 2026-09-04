import CoreGraphics
import SwiftUI

/// The box a preview lays itself out in.
///
/// A hover preview is a popover anchored to a row, so its budget comes from the active screen. A
/// pinned preview is a window the user resizes, so its budget is that window's content size. Both
/// hosts run the same measurement, wrapping and scroll decisions; only the box differs.
struct HoverPreviewSizeBudget: Equatable {
    /// `nil` means "derive from the active screen", the hover popover's behaviour.
    private let explicitSize: CGSize?

    static let popover = HoverPreviewSizeBudget(explicitSize: nil)

    static func window(_ size: CGSize) -> HoverPreviewSizeBudget {
        HoverPreviewSizeBudget(explicitSize: CGSize(width: max(1, size.width), height: max(1, size.height)))
    }

    var maxWidth: CGFloat {
        explicitSize?.width ?? HoverPreviewScreenMetrics.maxPopoverWidthPoints()
    }

    var maxMarkdownWidth: CGFloat {
        explicitSize?.width ?? HoverPreviewScreenMetrics.maxMarkdownPopoverWidthPoints()
    }

    var maxHeight: CGFloat {
        explicitSize?.height ?? HoverPreviewScreenMetrics.maxPopoverHeightPoints()
    }
}

private struct HoverPreviewSizeBudgetKey: EnvironmentKey {
    static let defaultValue = HoverPreviewSizeBudget.popover
}

extension EnvironmentValues {
    var hoverPreviewSizeBudget: HoverPreviewSizeBudget {
        get { self[HoverPreviewSizeBudgetKey.self] }
        set { self[HoverPreviewSizeBudgetKey.self] = newValue }
    }
}
