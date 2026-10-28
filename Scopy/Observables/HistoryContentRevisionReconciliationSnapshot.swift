import Foundation
import ScopyKit

struct HistoryContentRevisionReconciliationSnapshot {
    let knownRevisionsByItemID: [UUID: ClipboardItemContentRevision]
    let deletedItemIDs: Set<UUID>

    func revision(for itemID: UUID) -> ClipboardItemContentRevision? {
        knownRevisionsByItemID[itemID]
    }

    func wasDeleted(_ itemID: UUID) -> Bool {
        deletedItemIDs.contains(itemID)
    }

    /// Whether state held for `itemID` outside the list must be torn down.
    ///
    /// Active holders keep exact evidence even when the surrounding revision cache is evicted.
    func invalidates(
        itemID: UUID,
        currentRevision: ClipboardItemContentRevision?
    ) -> Bool {
        if wasDeleted(itemID) { return true }
        if let currentRevision, let known = revision(for: itemID), known != currentRevision {
            return true
        }
        return false
    }
}
