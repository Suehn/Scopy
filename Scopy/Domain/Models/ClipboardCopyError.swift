import Foundation

/// Why a history item could not be placed on the system pasteboard.
///
/// Copy is the one action whose failure is invisible: the pasteboard keeps whatever it held, so a
/// caller that treats "returned without throwing" as success closes the panel over an unchanged
/// pasteboard, and the Codex path then pastes the *previous* clipboard content into the frontmost
/// app. Every write path therefore reports failure instead of logging it.
public enum ClipboardCopyError: Error, Equatable, LocalizedError {
    /// The row was deleted between the click and the copy.
    case itemNotFound(UUID)
    /// The row exists but its payload (inline blob or external file) could not be read.
    case payloadUnavailable(UUID)
    /// The stored image bytes could not be turned into a pasteboard representation.
    case imageNotRenderable(UUID)
    /// `NSPasteboard` refused the representation; nothing usable was written.
    case pasteboardRejectedContent(UUID)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "That item is no longer in the history."
        case .payloadUnavailable:
            return "The stored content for that item could not be read."
        case .imageNotRenderable:
            return "The stored image could not be prepared for the clipboard."
        case .pasteboardRejectedContent:
            return "macOS refused to accept the content on the clipboard."
        }
    }
}
