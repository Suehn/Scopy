import Foundation

public struct MarkdownChatGPTLayoutScalePercent: RawRepresentable, Sendable, Equatable, Hashable {
    public static let minimumRawValue = 80
    public static let maximumRawValue = 200
    public static let magneticStep = 5
    public static let magneticThreshold: Double = 1.25

    public static let percent100 = MarkdownChatGPTLayoutScalePercent(rawValue: 100)
    public static let percent125 = MarkdownChatGPTLayoutScalePercent(rawValue: 125)

    public let rawValue: Int

    public init(settingsValue: Int) {
        self.init(rawValue: settingsValue)
    }

    public init(rawValue: Int) {
        self.rawValue = Self.clamped(rawValue)
    }

    public static func clamped(_ value: Int) -> Int {
        min(maximumRawValue, max(minimumRawValue, value))
    }

    public static func magneticValue(from value: Double) -> Int {
        guard value.isFinite else { return percent100.rawValue }
        let clampedValue = min(Double(maximumRawValue), max(Double(minimumRawValue), value))
        let nearestRawStep = (clampedValue / Double(magneticStep)).rounded() * Double(magneticStep)
        let nearestStep = min(Double(maximumRawValue), max(Double(minimumRawValue), nearestRawStep))
        if abs(clampedValue - nearestStep) <= magneticThreshold {
            return Int(nearestStep)
        }
        return clamped(Int(clampedValue.rounded()))
    }

    public var label: String {
        "\(rawValue)%"
    }

    public var fontScale: Double {
        1.0
    }

    public var browserZoomScale: Double {
        Double(rawValue) / 100.0
    }

    public var inverseBrowserZoomScale: Double {
        1.0 / browserZoomScale
    }

    public func layoutViewportWidth(outputSurfaceWidth: Double) -> Double {
        outputSurfaceWidth * inverseBrowserZoomScale
    }

    public var cacheKey: String {
        "chatgpt-layout-\(rawValue)"
    }
}

public enum MarkdownRenderLayoutConstants {
    public static let defaultChatGPTLayoutScale: MarkdownChatGPTLayoutScalePercent = .percent100
    public static let chatGPTContentInlinePadding: Double = 24
    public static let chatGPTContentTopPadding: Double = 20
    public static let chatGPTContentBottomPadding: Double = 24
    public static let chatGPTOutputSurfaceWidth: Double = 816
    public static let chatGPTDefaultThreadContentWidth: Double = 640
    public static let chatGPTWideThreadContentWidth: Double = 768
    /// The 816px output surface is defined as the canonical wide (48rem) desktop state, so the
    /// wide threshold equals the surface width: 100% scale and zoom-out render the 48rem column,
    /// while zooming in (logical viewport < 816) falls back to the narrow 40rem reading column.
    public static let chatGPTWideThreadMinimumViewportWidth: Double = chatGPTOutputSurfaceWidth

    public static var chatGPTRenderWidth: Double {
        chatGPTOutputSurfaceWidth
    }

    public static func renderWidth(for profile: MarkdownChatGPTLayoutScalePercent) -> Double {
        _ = profile
        return chatGPTOutputSurfaceWidth
    }

    public static func threadContentWidth(
        forLayoutViewportWidth layoutViewportWidth: Double
    ) -> Double {
        guard layoutViewportWidth.isFinite else {
            return chatGPTDefaultThreadContentWidth
        }
        return layoutViewportWidth >= chatGPTWideThreadMinimumViewportWidth
            ? chatGPTWideThreadContentWidth
            : chatGPTDefaultThreadContentWidth
    }
}
