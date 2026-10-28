import Foundation

/// Committed row values and exact removal sets. Every value belongs to the enclosing commit.
public enum HistoryChange: Sendable {
    case itemsChanged([ClipboardItemDTO], kind: HistoryItemChangeKind)
    case itemsRemoved([UUID])
    case itemsCleared(deletedItemIDs: [UUID])
}
