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
    case itemPinned(UUID)
    case itemUnpinned(UUID)
    case itemsCleared(keepPinned: Bool)
    case settingsChanged
}
