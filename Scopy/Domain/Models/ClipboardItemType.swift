import Foundation

/// 剪贴板项类型
public enum ClipboardItemType: String, Sendable {
    case text
    case rtf
    case html
    case image
    case file
    case other
}
