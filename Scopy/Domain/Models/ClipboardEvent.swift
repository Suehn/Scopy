import Foundation

/// A change the backend publishes to the UI.
public enum ClipboardEvent: Sendable {
    case history(CommittedHistoryChange)
    /// The commit log no longer covers this consumer's cursor. Re-read the loaded projection
    /// and retained item states; a gap alone is not evidence that an item was deleted.
    case historyResnapshotRequired(mutationSeq: Int64)
    case thumbnailUpdated(
        itemID: UUID,
        expectedType: ClipboardItemType,
        expectedContentHash: String,
        thumbnailPath: String
    )
    case settingsChanged
    case captureReadBlocked(Bool)
}
