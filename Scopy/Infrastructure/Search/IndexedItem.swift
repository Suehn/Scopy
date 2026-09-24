import Foundation

/// The fields fuzzy search filters, scores, and orders by.
struct IndexedItem: Sendable {
    let id: UUID
    let type: ClipboardItemType
    let plainTextLower: String
    let appBundleID: String?
    var lastUsedAt: Date
    var isPinned: Bool

    init(from item: ClipboardStoredItem) {
        self.id = item.id
        self.type = item.type
        var combined = item.plainText
        if let note = item.note, !note.isEmpty {
            combined.append("\n")
            combined.append(note)
        }
        self.plainTextLower = combined.lowercased()
        self.appBundleID = item.appBundleID
        self.lastUsedAt = item.lastUsedAt
        self.isPinned = item.isPinned
    }

    init(
        id: UUID,
        type: ClipboardItemType,
        plainTextLower: String,
        appBundleID: String?,
        lastUsedAt: Date,
        isPinned: Bool
    ) {
        self.id = id
        self.type = type
        self.plainTextLower = plainTextLower
        self.appBundleID = appBundleID
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
    }
}
