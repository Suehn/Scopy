import Foundation

/// Internal persistence model (DB row representation).
/// Used by StorageService / SearchEngine; not exposed to UI directly.
struct ClipboardStoredItem: Sendable {
    let id: UUID
    let type: ClipboardItemType
    let contentHash: String
    let plainText: String
    let appBundleID: String?
    let createdAt: Date
    var lastUsedAt: Date
    var useCount: Int
    var isPinned: Bool
    let sizeBytes: Int
    let storageRef: String?
    let rawData: Data?
}
