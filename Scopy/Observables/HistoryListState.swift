import Foundation
import ScopyKit

@MainActor
struct HistoryListState {
    private(set) var items: [ClipboardItemDTO] = []
    private(set) var pinnedItems: [ClipboardItemDTO] = []
    private(set) var unpinnedItems: [ClipboardItemDTO] = []
    private(set) var loadedCount: Int = 0
    private(set) var totalCount: Int = 0
    private(set) var canLoadMore: Bool = false

    private var itemIndexByID: [UUID: Int] = [:]

    mutating func replaceItems(_ newItems: [ClipboardItemDTO]) {
        items = newItems
        loadedCount = newItems.count
        rebuildDerivedState()
        recomputeCanLoadMore()
    }

    mutating func replacePage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool
    ) {
        items = newItems
        loadedCount = newItems.count
        totalCount = total
        canLoadMore = hasMore
        rebuildDerivedState()
    }

    mutating func appendPage(
        items newItems: [ClipboardItemDTO],
        total: Int,
        hasMore: Bool
    ) {
        items.append(contentsOf: newItems)
        loadedCount = items.count
        totalCount = total
        canLoadMore = hasMore
        rebuildDerivedState()
    }

    mutating func appendRecentPage(items newItems: [ClipboardItemDTO]) {
        items.append(contentsOf: newItems)
        loadedCount = items.count
        rebuildDerivedState()
        recomputeCanLoadMore()
    }

    mutating func updateTotalCount(_ total: Int) {
        totalCount = total
        recomputeCanLoadMore()
    }

    mutating func incrementTotalCount() {
        guard totalCount >= 0 else { return }
        totalCount += 1
        recomputeCanLoadMore()
    }

    mutating func decrementTotalCountIfNeeded(wasPresent: Bool, isUnfilteredList: Bool) {
        guard totalCount >= 0 else { return }
        if isUnfilteredList || wasPresent {
            totalCount = max(0, totalCount - 1)
        }
        recomputeCanLoadMore()
    }

    mutating func recomputeCanLoadMore() {
        guard totalCount >= 0 else { return }
        canLoadMore = loadedCount < totalCount
    }

    func indexOfItem(withID id: UUID) -> Int? {
        guard PerfFeatureFlags.historyIndexingEnabled else {
            return items.firstIndex { $0.id == id }
        }
        return itemIndexByID[id]
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
        guard items[index] != value else { return false }
        items[index] = value
        rebuildDerivedState()
        return true
    }

    @discardableResult
    mutating func removeItem(withID id: UUID) -> Bool {
        guard let index = indexOfItem(withID: id) else { return false }
        items.remove(at: index)
        loadedCount = items.count
        rebuildDerivedState()
        recomputeCanLoadMore()
        return true
    }

    @discardableResult
    mutating func insertOrMoveItemToFront(_ item: ClipboardItemDTO) -> Bool {
        if let existingIndex = indexOfItem(withID: item.id) {
            if existingIndex == 0 {
                return setItemIfChanged(at: existingIndex, to: item)
            }
            items.remove(at: existingIndex)
        }
        items.insert(item, at: 0)
        loadedCount = items.count
        rebuildDerivedState()
        recomputeCanLoadMore()
        return true
    }

    private mutating func rebuildDerivedState() {
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
