import Foundation

/// The sort key of the last unpinned row a recent page returned. The next page starts strictly
/// after it in `last_used_at DESC, id ASC` order, so rows inserted, deleted or moved above it do
/// not shift the continuation.
public struct RecentHistoryCursor: Sendable, Hashable {
    public let lastUsedAt: Date
    public let id: UUID

    public init(lastUsedAt: Date, id: UUID) {
        self.lastUsedAt = lastUsedAt
        self.id = id
    }

    public init(_ item: ClipboardItemDTO) {
        self.init(lastUsedAt: item.lastUsedAt, id: item.id)
    }

    /// Whether an unpinned row with this key belongs to a page after the cursor.
    public func precedes(lastUsedAt: Date, id: UUID) -> Bool {
        if lastUsedAt != self.lastUsedAt { return lastUsedAt < self.lastUsedAt }
        return id.uuidString > self.id.uuidString
    }

    public func precedes(_ item: ClipboardItemDTO) -> Bool {
        precedes(lastUsedAt: item.lastUsedAt, id: item.id)
    }
}

/// One page of the recent list, read from one database snapshot. The first page (no cursor)
/// carries every pinned row; a later page holds only the unpinned rows after its cursor.
public struct RecentHistoryPage: Sendable {
    /// Read in the same SQLite transaction as the rows, total and continuation.
    public let mutationSeq: Int64
    public let pinnedItems: [ClipboardItemDTO]
    public let items: [ClipboardItemDTO]
    public let total: Int
    /// Where the next page starts; `nil` once this page reached the oldest row.
    public let nextCursor: RecentHistoryCursor?

    public init(pinnedItems: [ClipboardItemDTO], items: [ClipboardItemDTO], total: Int,
                nextCursor: RecentHistoryCursor?, mutationSeq: Int64) {
        self.mutationSeq = mutationSeq
        self.pinnedItems = pinnedItems
        self.items = items
        self.total = total
        self.nextCursor = nextCursor
    }

    /// The page after `cursor` cut from an in-memory history in any order, as storage reads it.
    public init(slicing rows: [ClipboardItemDTO], limit: Int, after cursor: RecentHistoryCursor?, mutationSeq: Int64) {
        let inRecentOrder: (ClipboardItemDTO, ClipboardItemDTO) -> Bool = {
            RecentHistoryCursor($0).precedes($1)
        }
        let following = rows
            .filter { !$0.isPinned && cursor?.precedes($0) ?? true }
            .sorted(by: inRecentOrder)
        let page = Array(following.prefix(max(1, limit)))
        self.init(
            pinnedItems: cursor == nil ? rows.filter(\.isPinned).sorted(by: inRecentOrder) : [],
            items: page,
            total: rows.count,
            nextCursor: following.count > page.count ? page.last.map(RecentHistoryCursor.init) : nil,
            mutationSeq: mutationSeq
        )
    }
}

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
    public let useCount: Int
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
        storageRef: String?,
        useCount: Int
    ) {
        self.id = id
        self.type = type
        self.contentHash = contentHash
        self.plainText = plainText
        self.note = note
        self.appBundleID = appBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
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
            storageRef: storageRef,
            useCount: useCount
        )
        return copy
    }
}
