import Foundation
import ScopyKit

@MainActor
struct HistoryListState {
    private enum Pagination {
        /// The key of the last applied recent row; nil after the oldest row is loaded.
        case recent(continuingAfter: RecentHistoryCursor?, snapshotFloor: Int64)
        /// Search pages continue at the loaded row count; staged results may have no total yet.
        case search(hasMore: Bool)
    }

    private(set) var items: [ClipboardItemDTO] = []
    private(set) var pinnedItems: [ClipboardItemDTO] = []
    private(set) var unpinnedItems: [ClipboardItemDTO] = []
    private(set) var totalCount: Int = 0
    private var pagination: Pagination = .search(hasMore: false)
    private var totalMutationSeq: Int64?
    /// Bumped on every `items` mutation. Observing this instead of `items` avoids SwiftUI's
    /// element-wise array comparison (O(loaded plain-text bytes)) on the main thread.
    private(set) var projectionGeneration: UInt64 = 0
    private struct ItemPosition {
        let index: Int
        var mutationSeq: Int64?
    }
    private var itemIndexByID: [UUID: ItemPosition] = [:]

    var loadedCount: Int { items.count }

    var canLoadMore: Bool {
        switch pagination {
        case .recent(let cursor, _): return cursor != nil
        case .search(let hasMore): return hasMore
        }
    }

    /// Inserting, deleting or moving rows above this key leaves the next recent page unchanged.
    var recentCursor: RecentHistoryCursor? {
        guard case .recent(let cursor, _) = pagination else { return nil }
        return cursor
    }

    var recentSnapshotFloor: Int64? {
        guard case .recent(_, let floor) = pagination else { return nil }
        return floor
    }

    /// A tail page advances only its rows' watermarks. Earlier events can still update the
    /// loaded prefix, which that page did not read.
    func acceptsHistoryChange(itemID: UUID, mutationSeq: Int64) -> Bool {
        let floor = recentSnapshotFloor ?? -1
        return mutationSeq > max(floor, itemIndexByID[itemID]?.mutationSeq ?? -1)
    }

    #if DEBUG
    mutating func replaceItemsForTesting(_ newItems: [ClipboardItemDTO]) {
        items = newItems
        rebuildDerivedState()
        recomputeCanLoadMore()
    }

    #endif

    mutating func replacePage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool,
        mutationSeq: Int64
    ) {
        pagination = .search(hasMore: hasMore)
        totalMutationSeq = mutationSeq
        let previousItems = items
        let previousIndex = itemIndexByID
        items = newItems.map { item in
            guard let position = previousIndex[item.id],
                  let known = position.mutationSeq, known > mutationSeq else { return preservingThumbnail(in: item) }
            return previousItems[position.index]
        }
        totalCount = total
        rebuildDerivedState(snapshotVersion: mutationSeq)
    }

    mutating func replaceRecentPage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        continuingAfter cursor: RecentHistoryCursor?,
        mutationSeq: Int64
    ) {
        let resolvedItems = newItems.map { preservingThumbnail(in: $0) }
        pagination = .recent(continuingAfter: cursor, snapshotFloor: mutationSeq)
        items = resolvedItems
        totalCount = total
        totalMutationSeq = mutationSeq
        itemIndexByID.removeAll(keepingCapacity: true)
        rebuildDerivedState(snapshotVersion: mutationSeq)
    }

    mutating func appendPage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool,
        mutationSeq: Int64
    ) {
        appendItems(newItems, mutationSeq: mutationSeq)
        updateTotalCount(total, mutationSeq: mutationSeq)
        pagination = .search(hasMore: hasMore)
    }

    /// Appends rows of a recent page; `cursor` is where the rows after them start.
    mutating func appendRecentPage(
        items newItems: [ClipboardItemDTO],
        continuingAfter cursor: RecentHistoryCursor?,
        mutationSeq: Int64
    ) {
        guard let floor = recentSnapshotFloor else { return }
        pagination = .recent(continuingAfter: cursor, snapshotFloor: floor)
        for item in newItems where itemIndexByID[item.id] != nil {
            _ = upsertRecentItem(item, mutationSeq: mutationSeq)
        }
        appendItems(newItems, mutationSeq: mutationSeq)
    }

    private mutating func appendItems(_ newItems: [ClipboardItemDTO], mutationSeq: Int64) {
        // Appending keeps every existing index valid; extend the derived arrays instead of
        // rebuilding them for each page chunk.
        var index = items.count
        var accepted: [ClipboardItemDTO] = []
        for item in newItems {
            guard itemIndexByID[item.id] == nil else { continue }
            accepted.append(item)
            itemIndexByID[item.id] = ItemPosition(index: index, mutationSeq: mutationSeq)
            if item.isPinned {
                pinnedItems.append(item)
            } else {
                unpinnedItems.append(item)
            }
            index += 1
        }
        items.append(contentsOf: accepted)
        projectionGeneration &+= 1
    }

    mutating func updatePagination(total: Int, hasMore: Bool, mutationSeq: Int64) {
        updateTotalCount(total, mutationSeq: mutationSeq)
        pagination = .search(hasMore: hasMore)
    }

    mutating func updateTotalCount(_ total: Int, mutationSeq: Int64? = nil) {
        if let mutationSeq, let totalMutationSeq, mutationSeq < totalMutationSeq { return }
        totalCount = total
        if let mutationSeq { totalMutationSeq = mutationSeq }
        if case .recent(_, let floor) = pagination, total >= 0, total <= loadedCount {
            pagination = .recent(continuingAfter: nil, snapshotFloor: floor)
        }
        recomputeCanLoadMore()
    }

    /// Offset pages only: whether a recent page follows is the cursor's, not a count's.
    mutating func recomputeCanLoadMore() {
        guard case .search = pagination, totalCount >= 0 else { return }
        pagination = .search(hasMore: loadedCount < totalCount)
    }

    func mutationSeq(for itemID: UUID) -> Int64? { itemIndexByID[itemID]?.mutationSeq }

    func indexOfItem(withID id: UUID) -> Int? {
        itemIndexByID[id]?.index
    }

    func item(at index: Int) -> ClipboardItemDTO? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func item(withID id: UUID) -> ClipboardItemDTO? {
        guard let index = indexOfItem(withID: id) else { return nil }
        return items[index]
    }

    /// Thumbnail generation has a separate lifetime from history writes. A row hydrated before
    /// generation completed cannot revoke a later thumbnail for the same content identity.
    func preservingThumbnail(in item: ClipboardItemDTO) -> ClipboardItemDTO {
        guard item.thumbnailPath == nil,
              let current = self.item(withID: item.id),
              current.type == item.type, current.contentHash == item.contentHash,
              let thumbnailPath = current.thumbnailPath else { return item }
        return ClipboardItemDTO(
            id: item.id, type: item.type, contentHash: item.contentHash, plainText: item.plainText,
            note: item.note, appBundleID: item.appBundleID, createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt, isPinned: item.isPinned, sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes, thumbnailPath: thumbnailPath, storageRef: item.storageRef,
            useCount: item.useCount
        )
    }

    @discardableResult
    mutating func setItemIfChanged(at index: Int, to value: ClipboardItemDTO, mutationSeq: Int64? = nil) -> Bool {
        guard items.indices.contains(index) else { return false }
        if let mutationSeq {
            guard acceptsHistoryChange(itemID: value.id, mutationSeq: mutationSeq) else { return false }
            itemIndexByID[value.id]?.mutationSeq = mutationSeq
        }
        let value = preservingThumbnail(in: value)
        let previous = items[index]
        guard previous != value else { return false }
        items[index] = value
        if previous.isPinned == value.isPinned {
            // Same group, same position: replace in place instead of rebuilding every array.
            projectionGeneration &+= 1
            if value.isPinned {
                if let groupIndex = pinnedItems.firstIndex(where: { $0.id == value.id }) {
                    pinnedItems[groupIndex] = value
                }
            } else if let groupIndex = unpinnedItems.firstIndex(where: { $0.id == value.id }) {
                unpinnedItems[groupIndex] = value
            }
            return true
        }
        rebuildDerivedState()
        return true
    }

    @discardableResult
    mutating func removeItem(withID id: UUID, mutationSeq: Int64? = nil) -> Bool {
        if let mutationSeq, !acceptsHistoryChange(itemID: id, mutationSeq: mutationSeq) { return false }
        guard let index = indexOfItem(withID: id) else { return false }
        items.remove(at: index)
        rebuildDerivedState()
        recomputeCanLoadMore()
        return true
    }

    /// One filter + one derived-state rebuild keeps bulk cleanup O(loaded items + deleted IDs).
    @discardableResult
    mutating func removeItems(withIDs ids: Set<UUID>, mutationSeq: Int64? = nil) -> Int {
        guard !ids.isEmpty, !items.isEmpty else { return 0 }
        let previousCount = items.count
        let acceptedIDs = mutationSeq.map { version in
            Set(ids.filter { acceptsHistoryChange(itemID: $0, mutationSeq: version) })
        } ?? ids
        items.removeAll { acceptedIDs.contains($0.id) }
        let removedCount = previousCount - items.count
        guard removedCount > 0 else { return 0 }
        rebuildDerivedState()
        recomputeCanLoadMore()
        return removedCount
    }

    /// Puts a row back at the position it was removed from (clamped to the current count).
    mutating func insertItem(_ item: ClipboardItemDTO, at index: Int, mutationSeq: Int64? = nil) {
        guard indexOfItem(withID: item.id) == nil else { return }
        items.insert(item, at: min(max(0, index), items.count))
        rebuildDerivedState()
        itemIndexByID[item.id]?.mutationSeq = mutationSeq
        recomputeCanLoadMore()
    }

    @discardableResult
    mutating func upsertRecentItem(_ item: ClipboardItemDTO, mutationSeq: Int64? = nil) -> Bool {
        if let mutationSeq, !acceptsHistoryChange(itemID: item.id, mutationSeq: mutationSeq) { return false }
        let item = preservingThumbnail(in: item)
        // A row now sorting after the cursor belongs to a later page; kept here, it would sit
        // ahead of the rows that page still brings.
        if !item.isPinned, let recentCursor, recentCursor.precedes(item) {
            return removeItem(withID: item.id)
        }
        if let index = indexOfItem(withID: item.id) {
            if let mutationSeq { itemIndexByID[item.id]?.mutationSeq = mutationSeq }
            guard items[index] != item else { return false }
            items.remove(at: index)
        }
        let index = items.firstIndex {
            if $0.isPinned != item.isPinned { return item.isPinned }
            if $0.lastUsedAt != item.lastUsedAt { return item.lastUsedAt > $0.lastUsedAt }
            return item.id.uuidString < $0.id.uuidString
        } ?? items.endIndex
        items.insert(item, at: index)
        rebuildDerivedState()
        if let mutationSeq { itemIndexByID[item.id]?.mutationSeq = mutationSeq }
        recomputeCanLoadMore()
        return true
    }

    private mutating func rebuildDerivedState(snapshotVersion: Int64? = nil) {
        projectionGeneration &+= 1
        pinnedItems = []
        unpinnedItems = []
        pinnedItems.reserveCapacity(items.count)
        unpinnedItems.reserveCapacity(items.count)

        let previousIndex = itemIndexByID
        itemIndexByID = [:]
        itemIndexByID.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            itemIndexByID[item.id] = ItemPosition(
                index: index,
                mutationSeq: [snapshotVersion, previousIndex[item.id]?.mutationSeq].compactMap { $0 }.max()
            )
            if item.isPinned {
                pinnedItems.append(item)
            } else {
                unpinnedItems.append(item)
            }
        }
    }
}
