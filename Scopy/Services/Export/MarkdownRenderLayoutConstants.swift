import Foundation

public enum MarkdownRenderLayoutConstants {
    public static let chatGPTThreadContentWidth: Double = 640
    public static let chatGPTContentInlinePadding: Double = 24
    public static let chatGPTContentTopPadding: Double = 20
    public static let chatGPTContentBottomPadding: Double = 24

    public static var chatGPTRenderWidth: Double {
        chatGPTThreadContentWidth + (chatGPTContentInlinePadding * 2)
    }
}
