import Foundation

/// The kind of content a clipboard item holds.
public enum ClipboardItemType: String, Sendable {
    case text
    case rtf
    case html
    case image
    case file
    case other
}
