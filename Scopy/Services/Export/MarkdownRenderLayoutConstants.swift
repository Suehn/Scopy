import Foundation

public enum MarkdownChatGPTLayoutScalePercent: Int, CaseIterable, Sendable, Equatable {
    case percent100 = 100
    case percent125 = 125

    public init(settingsValue: Int) {
        switch settingsValue {
        case Self.percent125.rawValue:
            self = .percent125
        default:
            self = .percent100
        }
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

    public var threadContentWidth: Double {
        768
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

    public static var chatGPTThreadContentWidth: Double {
        defaultChatGPTLayoutScale.threadContentWidth
    }

    public static var chatGPTRenderWidth: Double {
        chatGPTOutputSurfaceWidth
    }

    public static func renderWidth(for profile: MarkdownChatGPTLayoutScalePercent) -> Double {
        _ = profile
        return chatGPTOutputSurfaceWidth
    }
}
