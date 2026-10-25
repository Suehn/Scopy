import Foundation
import ScopyKit

@MainActor
struct HistoryListState {
    private enum Pagination {
        /// The key of the last applied recent row; nil after the oldest row is loaded.
        case recent(continuingAfter: RecentHistoryCursor?)
        /// Search pages continue at the loaded row count; staged results may have no total yet.
        case search(hasMore: Bool)
    }

    private(set) var items: [ClipboardItemDTO] = []
    private(set) var pinnedItems: [ClipboardItemDTO] = []
    private(set) var unpinnedItems: [ClipboardItemDTO] = []
    private(set) var totalCount: Int = 0
    private var pagination: Pagination = .search(hasMore: false)
    /// Bumped on every `items` mutation. Observing this instead of `items` avoids SwiftUI's
    /// element-wise array comparison (O(loaded plain-text bytes)) on the main thread.
    private(set) var projectionGeneration: UInt64 = 0
    private var itemIndexByID: [UUID: Int] = [:]

    var loadedCount: Int { items.count }

    var canLoadMore: Bool {
        switch pagination {
        case .recent(let cursor): return cursor != nil
        case .search(let hasMore): return hasMore
        }
    }

    /// Inserting, deleting or moving rows above this key leaves the next recent page unchanged.
    var recentCursor: RecentHistoryCursor? {
        guard case .recent(let cursor) = pagination else { return nil }
        return cursor
    }

    mutating func replaceItems(_ newItems: [ClipboardItemDTO]) {
        items = newItems
        rebuildDerivedState()
        recomputeCanLoadMore()
    }

    mutating func replacePage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool
    ) {
        pagination = .search(hasMore: hasMore)
        items = newItems
        totalCount = total
        rebuildDerivedState()
    }

    mutating func replaceRecentPage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        continuingAfter cursor: RecentHistoryCursor?
    ) {
        pagination = .recent(continuingAfter: cursor)
        items = newItems
        totalCount = total
        rebuildDerivedState()
    }

    mutating func appendPage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool
    ) {
        appendItems(newItems)
        totalCount = total
        pagination = .search(hasMore: hasMore)
    }

    /// Appends rows of a recent page; `cursor` is where the rows after them start.
    mutating func appendRecentPage(items newItems: [ClipboardItemDTO], continuingAfter cursor: RecentHistoryCursor?) {
        appendItems(newItems)
        pagination = .recent(continuingAfter: cursor)
    }

    private mutating func appendItems(_ newItems: [ClipboardItemDTO]) {
        // Appending keeps every existing index valid; extend the derived arrays instead of
        // rebuilding them for each page chunk.
        var index = items.count
        var accepted: [ClipboardItemDTO] = []
        for item in newItems {
            guard itemIndexByID[item.id] == nil else { continue }
            accepted.append(item)
            itemIndexByID[item.id] = index
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

    mutating func updatePagination(total: Int, hasMore: Bool) {
        totalCount = total
        pagination = .search(hasMore: hasMore)
    }

    mutating func updateTotalCount(_ total: Int) {
        totalCount = total
        recomputeCanLoadMore()
    }

    mutating func decrementTotalCount(by count: Int) {
        guard totalCount >= 0, count > 0 else { return }
        totalCount = max(0, totalCount - count)
        recomputeCanLoadMore()
    }

    /// Offset pages only: whether a recent page follows is the cursor's, not a count's.
    mutating func recomputeCanLoadMore() {
        guard case .search = pagination, totalCount >= 0 else { return }
        pagination = .search(hasMore: loadedCount < totalCount)
    }

    func indexOfItem(withID id: UUID) -> Int? {
        itemIndexByID[id]
    }

    func item(at index: Int) -> ClipboardItemDTO? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func item(withID id: UUID) -> ClipboardItemDTO? {
        guard let index = indexOfItem(withID: id) else { return nil }
        return items[index]
    }

    @discardableResult
    mutating func setItemIfChanged(at index: Int, to value: ClipboardItemDTO) -> Bool {
        guard items.indices.contains(index) else { return false }
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
    mutating func removeItem(withID id: UUID) -> Bool {
        guard let index = indexOfItem(withID: id) else { return false }
        items.remove(at: index)
        rebuildDerivedState()
        recomputeCanLoadMore()
        return true
    }

    /// One filter + one derived-state rebuild keeps bulk cleanup O(loaded items + deleted IDs).
    @discardableResult
    mutating func removeItems(withIDs ids: Set<UUID>) -> Int {
        guard !ids.isEmpty, !items.isEmpty else { return 0 }
        let previousCount = items.count
        items.removeAll { ids.contains($0.id) }
        let removedCount = previousCount - items.count
        guard removedCount > 0 else { return 0 }
        rebuildDerivedState()
        recomputeCanLoadMore()
        return removedCount
    }

    /// Puts a row back at the position it was removed from (clamped to the current count).
    mutating func insertItem(_ item: ClipboardItemDTO, at index: Int) {
        guard indexOfItem(withID: item.id) == nil else { return }
        items.insert(item, at: min(max(0, index), items.count))
        rebuildDerivedState()
        recomputeCanLoadMore()
    }

    @discardableResult
    mutating func upsertRecentItem(_ item: ClipboardItemDTO) -> Bool {
        // A row now sorting after the cursor belongs to a later page; kept here, it would sit
        // ahead of the rows that page still brings.
        if !item.isPinned, let recentCursor, recentCursor.precedes(item) {
            return removeItem(withID: item.id)
        }
        if let index = indexOfItem(withID: item.id) {
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
        recomputeCanLoadMore()
        return true
    }

    private mutating func rebuildDerivedState() {
        projectionGeneration &+= 1
        pinnedItems = []
        unpinnedItems = []
        pinnedItems.reserveCapacity(items.count)
        unpinnedItems.reserveCapacity(items.count)

        itemIndexByID = [:]
        itemIndexByID.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            itemIndexByID[item.id] = index
            if item.isPinned {
                pinnedItems.append(item)
            } else {
                unpinnedItems.append(item)
            }
        }
    }
}
