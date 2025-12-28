import Foundation

/// 剪贴板项 DTO - 对应 v0.md 中的 ClipboardItem
/// 说明：UI-only 的派生展示字段（title/metadata）应在 Presentation 层生成。
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
    public let thumbnailPath: String?  // 缩略图路径 (v0.8)
    public let storageRef: String?     // 外部存储路径 (v0.8 - 用于原图预览)

    public init(
        id: UUID,
        type: ClipboardItemType,
        contentHash: String,
        plainText: String,
        note: String?,
        appBundleID: String?,
        createdAt: Date,
        lastUsedAt: Date,
        isPinned: Bool,
        sizeBytes: Int,
        fileSizeBytes: Int?,
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

    /// v0.16.2: 创建带有更新 isPinned 的新实例
    /// v0.23: 修复 - 使用 let 替代未使用的 var
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
