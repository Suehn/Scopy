import Foundation

/// One clipboard history item as the UI sees it.
/// Derived display fields (title, metadata) belong to the presentation layer.
public struct ClipboardItemDTO: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let type: ClipboardItemType
    public let contentHash: String
    public let plainText: String
    public let note: String?
    public let appBundleID: String?
    public let createdAt: Date
    public let lastUsedAt: Date
    public let isPinned: Bool
    public let sizeBytes: Int
    public let fileSizeBytes: Int?
    public let thumbnailPath: String?  // Thumbnail file path.
    public let storageRef: String?     // External payload path, for full-size preview.

    public init(
        id: UUID,
        type: ClipboardItemType,
        contentHash: String,
        plainText: String,
        note: String? = nil,
        appBundleID: String?,
        createdAt: Date,
        lastUsedAt: Date,
        isPinned: Bool,
        sizeBytes: Int,
        fileSizeBytes: Int? = nil,
        thumbnailPath: String?,
        storageRef: String?
    ) {
        self.id = id
        self.type = type
        self.contentHash = contentHash
        self.plainText = plainText
        self.note = note
        self.appBundleID = appBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.sizeBytes = sizeBytes
        self.fileSizeBytes = fileSizeBytes
        self.thumbnailPath = thumbnailPath
        self.storageRef = storageRef
    }

    /// A copy with `isPinned` replaced.
    public func withPinned(_ pinned: Bool) -> ClipboardItemDTO {
        let copy = ClipboardItemDTO(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            note: note,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            isPinned: pinned,
            sizeBytes: sizeBytes,
            fileSizeBytes: fileSizeBytes,
            thumbnailPath: thumbnailPath,
            storageRef: storageRef
        )
        return copy
    }
}
