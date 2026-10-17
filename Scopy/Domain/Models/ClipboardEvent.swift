import Foundation

/// A change the backend publishes to the UI.
public enum ClipboardEvent: Sendable {
    case newItem(ClipboardItemDTO)
    case itemUpdated(ClipboardItemDTO)  // Moves the item to the top.
    case itemContentUpdated(ClipboardItemDTO) // Content changed; the item keeps its position.
    case thumbnailUpdated(
        itemID: UUID,
        expectedType: ClipboardItemType,
        expectedContentHash: String,
        thumbnailPath: String
    )
    case itemDeleted(UUID)
    case itemsRemoved([UUID])
    /// The row after the change: recent pages after the first skip pinned rows, so a row pinned
    /// before it was loaded reaches the pinned group only through this event.
    case itemPinned(ClipboardItemDTO)
    case itemUnpinned(ClipboardItemDTO)
    case itemsCleared(keepPinned: Bool)
    case settingsChanged
    case captureReadBlocked(Bool)
}
