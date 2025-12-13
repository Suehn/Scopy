import Foundation

/// Internal persistence model (DB row representation).
/// Used by StorageService / SearchEngine; not exposed to UI directly.
public struct ClipboardStoredItem: Sendable {
    public let id: UUID
    public let type: ClipboardItemType
    public let contentHash: String
    public let plainText: String
    public let appBundleID: String?
    public let createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    public var isPinned: Bool
    public let sizeBytes: Int
    public let storageRef: String?
    public let rawData: Data?
}
