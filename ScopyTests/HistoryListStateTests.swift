import XCTest
@testable import Scopy
import ScopyKit

@MainActor
final class HistoryListStateTests: XCTestCase {
    func testReplacePageMaintainsDerivedStateAndIndex() {
        let pinned = makeItem(text: "pinned", isPinned: true)
        let first = makeItem(text: "first")
        let secondPinned = makeItem(text: "second pinned", isPinned: true)
        var state = HistoryListState()

        state.replacePage(items: [pinned, first, secondPinned], total: 10, hasMore: true)

        XCTAssertEqual(state.items.map(\.id), [pinned.id, first.id, secondPinned.id])
        XCTAssertEqual(state.pinnedItems.map(\.id), [pinned.id, secondPinned.id])
        XCTAssertEqual(state.unpinnedItems.map(\.id), [first.id])
        XCTAssertEqual(state.indexOfItem(withID: secondPinned.id), 2)
        XCTAssertEqual(state.loadedCount, 3)
        XCTAssertEqual(state.totalCount, 10)
        XCTAssertTrue(state.canLoadMore)
    }

    func testAppendPageMaintainsIndexAcrossExistingAndNewItems() {
        let first = makeItem(text: "first")
        let second = makeItem(text: "second")
        var state = HistoryListState()
        state.replacePage(items: [first], total: 1, hasMore: false)

        state.appendPage(items: [second], total: 2, hasMore: false)

        XCTAssertEqual(state.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.indexOfItem(withID: first.id), 0)
        XCTAssertEqual(state.indexOfItem(withID: second.id), 1)
        XCTAssertEqual(state.loadedCount, 2)
        XCTAssertEqual(state.totalCount, 2)
        XCTAssertFalse(state.canLoadMore)
    }

    func testAppendRecentPageUsesExistingTotalCount() {
        let first = makeItem(text: "first")
        let second = makeItem(text: "second")
        var state = HistoryListState()
        state.replacePage(items: [first], total: 3, hasMore: true)

        state.appendRecentPage(items: [second])

        XCTAssertEqual(state.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.loadedCount, 2)
        XCTAssertEqual(state.totalCount, 3)
        XCTAssertTrue(state.canLoadMore)
    }

    func testSetItemIfChangedUpdatesInPlaceAndDerivedPinnedSplit() {
        let first = makeItem(text: "first")
        let second = makeItem(text: "second")
        var state = HistoryListState()
        state.replacePage(items: [first, second], total: 2, hasMore: false)

        let updatedSecond = second.withPinned(true)
        let didUpdate = state.setItemIfChanged(at: 1, to: updatedSecond)

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(state.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.pinnedItems.map(\.id), [second.id])
        XCTAssertEqual(state.unpinnedItems.map(\.id), [first.id])
        XCTAssertEqual(state.indexOfItem(withID: second.id), 1)
    }

    func testRemoveItemMaintainsContinuousIndexAndPaging() {
        let first = makeItem(text: "first")
        let second = makeItem(text: "second")
        let third = makeItem(text: "third")
        var state = HistoryListState()
        state.replacePage(items: [first, second, third], total: 4, hasMore: true)

        let removed = state.removeItem(withID: second.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(state.items.map(\.id), [first.id, third.id])
        XCTAssertEqual(state.indexOfItem(withID: first.id), 0)
        XCTAssertNil(state.indexOfItem(withID: second.id))
        XCTAssertEqual(state.indexOfItem(withID: third.id), 1)
        XCTAssertEqual(state.loadedCount, 2)
        XCTAssertEqual(state.totalCount, 4)
        XCTAssertTrue(state.canLoadMore)
    }

    func testInsertOrMoveItemToFrontPreservesMoveBehavior() {
        let first = makeItem(text: "first")
        let second = makeItem(text: "second")
        var state = HistoryListState()
        state.replacePage(items: [first, second], total: 2, hasMore: false)

        let moved = state.insertOrMoveItemToFront(second)

        XCTAssertTrue(moved)
        XCTAssertEqual(state.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(state.indexOfItem(withID: second.id), 0)
        XCTAssertEqual(state.indexOfItem(withID: first.id), 1)
        XCTAssertEqual(state.loadedCount, 2)
        XCTAssertFalse(state.canLoadMore)
    }

    func testIncrementAndDecrementTotalCountPreserveCurrentPagingSemantics() {
        let first = makeItem(text: "first")
        var state = HistoryListState()
        state.replacePage(items: [first], total: 1, hasMore: false)

        state.incrementTotalCount()
        XCTAssertEqual(state.totalCount, 2)
        XCTAssertTrue(state.canLoadMore)

        state.decrementTotalCountIfNeeded(wasPresent: false, isUnfilteredList: false)
        XCTAssertEqual(state.totalCount, 2)
        XCTAssertTrue(state.canLoadMore)

        state.decrementTotalCountIfNeeded(wasPresent: true, isUnfilteredList: false)
        XCTAssertEqual(state.totalCount, 1)
        XCTAssertFalse(state.canLoadMore)
    }

    private func makeItem(text: String, isPinned: Bool = false) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: UUID().uuidString,
            plainText: text,
            appBundleID: "com.scopy.tests",
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: isPinned,
            sizeBytes: text.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }
}
