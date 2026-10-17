import Observation
@testable import ScopyKit
import XCTest

@MainActor
final class HistoryViewModelRegressionTests: XCTestCase {
    func testDeleteRemovesRowImmediatelyAndCommitsAfterWindow() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let target = viewModel.items[1]

        await viewModel.delete(target)

        XCTAssertFalse(viewModel.items.contains { $0.id == target.id }, "The row leaves the list at once")
        XCTAssertEqual(viewModel.loadedCount, 2)
        XCTAssertEqual(viewModel.totalCount, 3, "The count still includes a backend row inside the undo window")
        XCTAssertEqual(viewModel.undoableDeletionID, target.id)
        XCTAssertTrue(service.items.contains { $0.id == target.id }, "The backend delete waits for the undo window")

        await waitUntil(timeout: 2.0) { !service.items.contains { $0.id == target.id } }
        XCTAssertFalse(service.items.contains { $0.id == target.id })
        XCTAssertNil(viewModel.undoableDeletionID)
        await viewModel.handleEvent(.itemDeleted(target.id))
        await waitUntil(timeout: 1) { viewModel.totalCount == 2 }
        XCTAssertEqual(viewModel.totalCount, 2)
    }

    func testUndoRestoresRowAndSelection() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let order = viewModel.items.map(\.id)
        let target = viewModel.items[1]

        await viewModel.delete(target)
        await viewModel.undoPendingDeletion()

        XCTAssertEqual(viewModel.items.map(\.id), order, "Undo puts the row back where the reload places it")
        XCTAssertEqual(viewModel.selectedID, target.id)
        XCTAssertNil(viewModel.undoableDeletionID)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(service.items.contains { $0.id == target.id }, "Undo cancels the deferred backend delete")
    }

    func testRecaptureDuringUndoWindowCancelsDeletion() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let target = viewModel.items[1]

        await viewModel.delete(target)
        await viewModel.handleEvent(.itemUpdated(target))

        XCTAssertTrue(viewModel.items.contains { $0.id == target.id }, "The republished row is back")
        XCTAssertNil(viewModel.undoableDeletionID)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(service.items.contains { $0.id == target.id }, "Committing would delete what was just copied")
    }

    func testQuitDrainsPanelCloseAndPendingDeletion() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.longUndoWindowRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let target = viewModel.items[1]

        await viewModel.delete(target)
        let started = expectation(description: "Panel close sent the delete")
        service.suspendNextDelete = true
        service.onDeleteStarted = { started.fulfill() }
        let close = Task { await viewModel.commitPendingDeletionNow() }
        await fulfillment(of: [started], timeout: 1)
        let second = viewModel.items[0]
        await viewModel.delete(second)
        var finished = false
        let quit = Task {
            let success = await viewModel.prepareForTermination()
            finished = true
            return success
        }
        await waitUntil(timeout: 1) { !service.items.contains { $0.id == second.id } }
        XCTAssertFalse(finished, "Quit still waits for the delete already sent by panel close")
        service.resumeDelete()
        await close.value
        let success = await quit.value
        XCTAssertTrue(success)

        XCTAssertFalse(service.items.contains { $0.id == target.id })
        XCTAssertNil(viewModel.undoableDeletionID)
    }

    func testCommitFailureRevivesRowAndReportsError() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.longUndoWindowRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let target = viewModel.items[1]
        viewModel.selectedID = target.id
        service.deleteShouldFail = true

        await viewModel.deleteSelectedItem()
        XCTAssertFalse(viewModel.items.contains { $0.id == target.id })

        let canQuit = await viewModel.prepareForTermination()
        XCTAssertFalse(canQuit, "An uncommitted deletion cancels normal Quit")
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.items.map(\.id), service.items.map(\.id), "A failed commit revives the row")
        XCTAssertEqual(viewModel.selectedID, target.id)
    }

    func testDeletesStartedDuringACommitAreAllSentAndTheNewestStaysUndoable() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 4))
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.longUndoWindowRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let (first, second, third, fourth) = (viewModel.items[0], viewModel.items[1], viewModel.items[2], viewModel.items[3])

        await viewModel.delete(first)
        // The second delete commits the first one; the backend suspends that commit, and the third
        // delete starts while the second is still inside it.
        let firstDeleteStarted = expectation(description: "Backend delete of the first row started")
        service.suspendNextDelete = true
        service.onDeleteStarted = { firstDeleteStarted.fulfill() }
        let secondDelete = Task { await viewModel.delete(second) }
        await fulfillment(of: [firstDeleteStarted], timeout: 1.0)
        let thirdDelete = Task { await viewModel.delete(third) }
        await waitUntil(timeout: 1.0) { viewModel.undoableDeletionID == third.id }
        XCTAssertEqual(viewModel.undoableDeletionID, third.id, "The newest delete owns the undo slot")
        service.resumeDelete()
        await secondDelete.value
        await thirdDelete.value

        XCTAssertEqual(service.items.map(\.id), [third.id, fourth.id], "Both earlier deletes reached the backend")
        XCTAssertEqual(viewModel.items.map(\.id), [fourth.id])

        // The backend publishes the two deletions; the third row must still be undoable in place.
        await viewModel.handleEvent(.itemDeleted(first.id))
        await viewModel.handleEvent(.itemDeleted(second.id))
        await viewModel.undoPendingDeletion()
        XCTAssertEqual(viewModel.items.map(\.id), [third.id, fourth.id], "Undo after real deletion events puts the row back")
        XCTAssertEqual(service.items.map(\.id), [third.id, fourth.id])
    }

    func testPagingSkipsTheRowWhoseDeleteIsStillDeferred() async {
        let all = makeItems(count: 60)
        let service = HistoryViewModelRegressionService(items: all)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        defer { viewModel.stop() }
        await viewModel.load()
        XCTAssertEqual(viewModel.items.count, HistoryViewModel.initialPageSize)

        await viewModel.delete(viewModel.items[0])
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.items.map(\.id), all.dropFirst().map(\.id), "The next page starts after the row the backend still holds")
    }

    func testPagingAfterADeletionEventStillSkipsThePendingRow() async {
        let all = makeItems(count: 120)
        let service = HistoryViewModelRegressionService(items: all)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.longUndoWindowRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()

        await viewModel.delete(viewModel.items[0])
        await viewModel.delete(viewModel.items[0])
        // The first delete was committed by the second; its backend event arrives before paging.
        await viewModel.handleEvent(.itemDeleted(all[0].id))
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.items.map(\.id), all.dropFirst(2).map(\.id), "No duplicate and no gap around the deferred row")
    }

    func testUndoOfADeepRowKeepsTheLoadedPages() async {
        let all = makeItems(count: 60)
        let service = HistoryViewModelRegressionService(items: all)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        defer { viewModel.stop() }
        await viewModel.load()
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.items.count, 60)
        let target = viewModel.items[55]

        await viewModel.delete(target)
        let newest = makeItem(text: "captured meanwhile", age: -1)
        service.items.insert(newest, at: 0)
        await viewModel.handleEvent(.newItem(newest))
        await viewModel.undoPendingDeletion()

        XCTAssertEqual(viewModel.items.map(\.id), [newest.id] + all.map(\.id), "Undo puts the row back between its neighbours without dropping the loaded pages")
        XCTAssertEqual(viewModel.selectedID, target.id)
    }

    func testQuickSlotHintsFollowTheDisplayedOrder() async {
        var items = makeItems(count: 3)
        items[0] = items[0].withPinned(true)
        let service = HistoryViewModelRegressionService(items: items)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        defer { viewModel.stop() }
        await viewModel.load()

        viewModel.setQuickSlotHintsVisible(true)
        XCTAssertEqual(viewModel.rowLiveState.state(for: items[1].id).quickSlot, 2)

        viewModel.isPinnedCollapsed = true
        XCTAssertEqual(viewModel.rowLiveState.state(for: items[1].id).quickSlot, 1, "Collapsing the pinned row renumbers the hints")
        XCTAssertNil(viewModel.rowLiveState.state(for: items[0].id).quickSlot)

        let newest = makeItem(text: "newest", age: -1)
        service.items.insert(newest, at: 0)
        await viewModel.handleEvent(.newItem(newest))
        XCTAssertEqual(viewModel.rowLiveState.state(for: newest.id).quickSlot, 1, "A new front row takes slot 1")
        XCTAssertEqual(viewModel.rowLiveState.state(for: items[1].id).quickSlot, 2)

        viewModel.setQuickSlotHintsVisible(false)
        XCTAssertNil(viewModel.rowLiveState.state(for: newest.id).quickSlot)
    }

    func testQuickSlotCopiesNthDisplayedRowAndSkipsCollapsedPinned() async {
        var items = makeItems(count: 3)
        items[0] = items[0].withPinned(true)
        let service = HistoryViewModelRegressionService(items: items)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        defer { viewModel.stop() }
        var closeCount = 0
        viewModel.closePanelHandler = { closeCount += 1 }
        await viewModel.load()

        await viewModel.selectQuickSlot(1)
        XCTAssertEqual(service.copiedItemIDs, [items[0].id], "Slot 1 is the first displayed row, the pinned one")
        XCTAssertEqual(closeCount, 1, "⌘n copies and closes like ⏎")

        viewModel.isPinnedCollapsed = true
        await viewModel.selectQuickSlot(1)
        XCTAssertEqual(service.copiedItemIDs.last, items[1].id, "A collapsed pinned row takes no slot")

        await viewModel.selectQuickSlot(3)
        XCTAssertEqual(service.copiedItemIDs.count, 2, "A slot past the displayed rows does nothing")
    }

    func testKeyboardNavigationSkipsCollapsedPinnedRows() async {
        var items = makeItems(count: 3)
        items[0] = items[0].withPinned(true)
        let service = HistoryViewModelRegressionService(items: items)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        defer { viewModel.stop() }
        await viewModel.load()
        let pinnedID = items[0].id

        await viewModel.selectCurrent()
        XCTAssertTrue(service.copiedItemIDs.isEmpty, "Enter without a selection must not copy")
        viewModel.highlightPrevious()
        XCTAssertEqual(viewModel.selectedID, items[2].id)
        viewModel.highlightNext()
        XCTAssertEqual(viewModel.selectedID, pinnedID, "Down wraps from the last row")
        viewModel.highlightNext()
        XCTAssertEqual(viewModel.selectedID, items[1].id)
        viewModel.highlightPrevious()
        XCTAssertEqual(viewModel.selectedID, pinnedID)
        viewModel.isPinnedCollapsed = true
        XCTAssertNil(viewModel.selectedID, "Collapsing hides the pinned row, so it cannot stay the ⏎/⌥⌫ target")

        viewModel.highlightNext()
        XCTAssertEqual(viewModel.selectedID, items[1].id)
        viewModel.highlightPrevious()
        XCTAssertEqual(viewModel.selectedID, items[2].id, "Wrapping upward skips the hidden pinned row")
        var closeCount = 0
        viewModel.closePanelHandler = { closeCount += 1 }
        await viewModel.selectCurrent()
        XCTAssertEqual(service.copiedItemIDs, [items[2].id])
        XCTAssertEqual(closeCount, 1)
    }

    func testDeletingTheSelectedRowChoosesItsVisibleNeighbourOrClearsSelection() async {
        let cases: [(count: Int, deletedIndex: Int, nextIndex: Int?)] = [
            (3, 1, 2), (3, 2, 1), (1, 0, nil)
        ]
        for scenario in cases {
            let items = makeItems(count: scenario.count)
            let service = HistoryViewModelRegressionService(items: items)
            let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
            viewModel.configureTiming(.longUndoWindowRegressionTests)
            await viewModel.load()
            viewModel.selectedID = items[scenario.deletedIndex].id

            await viewModel.deleteSelectedItem()

            let nextID = scenario.nextIndex.map { items[$0].id }
            XCTAssertEqual(viewModel.selectedID, nextID)
            XCTAssertEqual(viewModel.items.map(\.id), items.enumerated().filter {
                $0.offset != scenario.deletedIndex
            }.map { $0.element.id })
            await viewModel.selectCurrent()
            XCTAssertEqual(service.copiedItemIDs, nextID.map { [$0] } ?? [])
            await viewModel.undoPendingDeletion()
            viewModel.stop()
        }
    }

    func testPinnedPageQuotaAndPinEventsPreserveTheObservedGroups() async {
        let items = makeItems(count: 120).enumerated().map { index, item in
            item.withPinned(index < 30)
        }
        let service = HistoryViewModelRegressionService(items: items)
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        defer { viewModel.stop() }
        await viewModel.load()

        XCTAssertEqual(viewModel.pinnedItems.map(\.id), items.prefix(30).map(\.id))
        XCTAssertEqual(viewModel.unpinnedItems.count, HistoryViewModel.initialPageSize)
        XCTAssertEqual(viewModel.loadedCount, 80)
        XCTAssertEqual(settings.storageStats.itemCount, 120)
        XCTAssertTrue(viewModel.canLoadMore)
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.items.map(\.id), items.map(\.id))
        XCTAssertFalse(viewModel.canLoadMore)
        let fetchCount = service.recentUnpinnedFetchCallCount
        await viewModel.loadMore()
        XCTAssertEqual(service.recentUnpinnedFetchCallCount, fetchCount)

        let target = items[30]
        let invalidated = expectation(description: "Pin event updates the observed list groups")
        withObservationTracking {
            _ = viewModel.pinnedItems
            _ = viewModel.unpinnedItems
        } onChange: {
            invalidated.fulfill()
        }
        await viewModel.handleEvent(.itemPinned(target.id))
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertEqual(viewModel.pinnedItems.map(\.id), items.prefix(31).map(\.id))
        XCTAssertEqual(viewModel.unpinnedItems.map(\.id), items.dropFirst(31).map(\.id))
        XCTAssertEqual(viewModel.items.map(\.id), items.map(\.id))
    }

    func testBulkCleanupKeepsLoadedDepthAndDoesNotCountTheSameCommitTwice() async {
        let items = makeItems(count: 400)
        let service = HistoryViewModelRegressionService(items: items)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        defer { viewModel.stop() }
        await viewModel.load()
        await viewModel.loadMore()
        let loadedIDs = viewModel.items.map(\.id)
        let deletedIDs = [items[3].id, items[31].id, items[370].id]
        service.items.removeAll { deletedIDs.contains($0.id) }

        await viewModel.handleEvent(.itemsRemoved(deletedIDs))

        XCTAssertEqual(viewModel.items.map(\.id), loadedIDs.filter { !deletedIDs.contains($0) })
        XCTAssertEqual(viewModel.loadedCount, 348)
        XCTAssertEqual(viewModel.totalCount, 397)
        XCTAssertTrue(viewModel.canLoadMore)
        await viewModel.load()
        await viewModel.handleEvent(.itemsRemoved(deletedIDs))
        XCTAssertEqual(viewModel.totalCount, 397)
        XCTAssertEqual(viewModel.items.map(\.id), service.items.prefix(HistoryViewModel.initialPageSize).map(\.id))
    }

    func testEmptyStagedPrefilterIsNotPublishedWhileRefineIsPending() async {
        let match = makeItem(text: "needle match", age: 1)
        let other = makeItem(text: "other", age: 2)
        let service = HistoryViewModelRegressionService(items: [match, other])
        service.returnsStagedFirstPage = true
        service.prefilterItems = []
        service.suspendNextRefine = true
        service.refineShouldFail = true
        let refineStarted = expectation(description: "Refine started")
        service.onRefineStarted = { refineStarted.fulfill() }
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        let revision = viewModel.projectionGeneration

        viewModel.searchMode = .fuzzyPlus
        viewModel.searchQuery = "needle"
        viewModel.search()
        await fulfillment(of: [refineStarted], timeout: 1.0)

        XCTAssertEqual(viewModel.items.map(\.id), [match.id, other.id], "The empty prefilter page is not published")
        XCTAssertEqual(viewModel.projectionGeneration, revision)
        XCTAssertTrue(viewModel.isLoading, "Loading lasts until the refine lands")

        let oldSelection = other.id
        viewModel.selectedID = oldSelection
        service.resumeRefine()
        await waitForSearchToFinish(in: viewModel)
        XCTAssertEqual(viewModel.items.map(\.id), [match.id, other.id])
        XCTAssertEqual(viewModel.selectedID, oldSelection)
        XCTAssertNotNil(viewModel.fetchFailureMessage)
        XCTAssertEqual(viewModel.searchCoverage, .incomplete)
        service.refineShouldFail = false
        service.suspendNextRefine = false
        service.onRefineStarted = nil
        viewModel.search()
        await waitForSearchToFinish(in: viewModel)
        XCTAssertEqual(viewModel.items.map(\.id), [match.id])
        XCTAssertEqual(viewModel.projectionGeneration, revision + 1, "The refine replaces the rows once")
        XCTAssertEqual(viewModel.searchCoverage, .complete)
    }

    func testNewItemRefreshesActiveSemanticSearchWithoutDisturbingSelectionOrScroll() async {
        let original = makeItem(text: "needle original", age: 1)
        let service = HistoryViewModelRegressionService(items: [original])
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }

        await viewModel.load()
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)

        viewModel.selectedID = original.id
        viewModel.scrollDidStart()
        let newItem = makeItem(text: "new needle result", age: 0)
        service.items.insert(newItem, at: 0)

        let refreshed = expectation(description: "Active search projection refreshed")
        withObservationTracking {
            _ = viewModel.projectionGeneration
        } onChange: {
            refreshed.fulfill()
        }

        await viewModel.handleEvent(.newItem(newItem))
        await fulfillment(of: [refreshed], timeout: 1.0)

        XCTAssertEqual(Set(viewModel.items.map(\.id)), [original.id, newItem.id])
        XCTAssertEqual(viewModel.selectedID, original.id)
        XCTAssertTrue(viewModel.isScrolling)
        XCTAssertEqual(service.searchRequests.count, 2)
    }

    func testNewItemJoiningAFilteredListCountsOnceAndKeepsTheOldestRowReachable() async {
        let items = makeItems(count: HistoryViewModel.initialPageSize + 1)
        let service = HistoryViewModelRegressionService(items: items)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        await viewModel.load()
        viewModel.typeFilter = .text
        viewModel.search()
        await waitForSearchToFinish(in: viewModel)
        XCTAssertEqual(viewModel.loadedCount, HistoryViewModel.initialPageSize)

        let newItem = makeItem(text: "new", age: -1)
        service.items.insert(newItem, at: 0)
        await viewModel.handleEvent(.newItem(newItem))
        await viewModel.handleEvent(.newItem(newItem))

        XCTAssertEqual(viewModel.items.first?.id, newItem.id)
        XCTAssertEqual(viewModel.totalCount, items.count + 1)
        XCTAssertTrue(viewModel.canLoadMore)
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.items.last?.id, items.last?.id)
    }

    func testFailedEventDrivenSearchKeepsRowsButMarksCoverageIncomplete() async {
        let original = makeItem(text: "needle original", age: 1)
        let service = HistoryViewModelRegressionService(items: [original])
        let viewModel = HistoryViewModel(
            service: service,
            settingsViewModel: SettingsViewModel(service: service)
        )
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }

        await viewModel.load()
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)

        viewModel.selectedID = original.id
        viewModel.scrollDidStart()
        service.searchShouldFail = true
        let newItem = makeItem(text: "new needle result", age: 0)
        service.items.insert(newItem, at: 0)

        let coverageChanged = expectation(description: "Failed refresh becomes incomplete")
        withObservationTracking {
            _ = viewModel.searchCoverage
        } onChange: {
            coverageChanged.fulfill()
        }

        await viewModel.handleEvent(.newItem(newItem))
        await fulfillment(of: [coverageChanged], timeout: 1.0)

        XCTAssertEqual(viewModel.items.map(\.id), [original.id])
        XCTAssertEqual(viewModel.selectedID, original.id)
        XCTAssertTrue(viewModel.isScrolling)
        XCTAssertEqual(viewModel.searchCoverage, .incomplete)
        XCTAssertEqual(viewModel.primarySearchStatusLabel, "Partial")
    }

    func testFailedEventDrivenRefreshCannotLeaveStagedCoverageTerminal() async {
        let original = makeItem(text: "needle original", age: 1)
        let service = HistoryViewModelRegressionService(items: [original])
        service.returnsStagedFirstPage = true
        service.refineShouldFail = true
        let refineStarted = expectation(description: "Initial refine started")
        service.onRefineStarted = { refineStarted.fulfill() }

        let viewModel = HistoryViewModel(
            service: service,
            settingsViewModel: SettingsViewModel(service: service)
        )
        viewModel.configureTiming(.immediateRegressionTests)
        defer {
            service.resumeRefine()
            viewModel.stop()
        }

        viewModel.searchMode = .fuzzy
        viewModel.searchQuery = "needle"
        viewModel.search()
        await fulfillment(of: [refineStarted], timeout: 1.0)
        XCTAssertEqual(viewModel.searchCoverage, .stagedRefine)

        service.searchShouldFail = true
        let newItem = makeItem(text: "another needle", age: 0)
        service.items.insert(newItem, at: 0)
        let coverageChanged = expectation(description: "Staged refresh failure becomes incomplete")
        withObservationTracking {
            _ = viewModel.searchCoverage
        } onChange: {
            coverageChanged.fulfill()
        }

        await viewModel.handleEvent(.newItem(newItem))
        await fulfillment(of: [coverageChanged], timeout: 1.0)

        XCTAssertEqual(viewModel.searchCoverage, .incomplete)
        XCTAssertNotEqual(viewModel.primarySearchStatusLabel, "Calibrating")
    }

    func testFailedRefineBecomesIncompleteAndRetryRecovers() async {
        let results = (0..<60).map { makeItem(text: "needle \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: results)
        service.returnsStagedFirstPage = true
        service.refineShouldFail = true
        let refineStarted = expectation(description: "Refine search started")
        service.onRefineStarted = { refineStarted.fulfill() }

        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.immediateRegressionTests)
        defer {
            service.resumeRefine()
            viewModel.stop()
        }

        viewModel.searchMode = .fuzzy
        viewModel.searchQuery = "needle"
        viewModel.search()
        await fulfillment(of: [refineStarted], timeout: 1.0)
        XCTAssertTrue(viewModel.searchCoverage.isStagedRefine)
        viewModel.selectedID = results[0].id
        viewModel.scrollDidStart()

        let coverageChanged = expectation(description: "Refine failure reached terminal coverage")
        withObservationTracking {
            _ = viewModel.searchCoverage
        } onChange: {
            coverageChanged.fulfill()
        }

        service.resumeRefine()
        await fulfillment(of: [coverageChanged], timeout: 1.0)

        XCTAssertEqual(viewModel.searchCoverage, .incomplete)
        XCTAssertEqual(viewModel.primarySearchStatusLabel, "Partial")
        XCTAssertEqual(
            viewModel.searchCoverageHint,
            "Results are incomplete; order and coverage may be partial."
        )
        XCTAssertTrue(viewModel.searchStatusSummary.contains("Coverage: Partial"))
        XCTAssertEqual(viewModel.selectedID, results[0].id)
        XCTAssertTrue(viewModel.isScrolling)

        service.refineShouldFail = false
        viewModel.search()
        // Loading ends with the staged page; the refine lands after it.
        await waitUntil(timeout: 5) { viewModel.searchCoverage == .complete }

        XCTAssertEqual(viewModel.searchCoverage, .complete)
        XCTAssertTrue(service.searchRequests.last?.forceFullFuzzy == true)
        XCTAssertEqual(viewModel.selectedID, results[0].id)
        XCTAssertTrue(viewModel.isScrolling)
    }

    func testLoadRefetchesOnceWhenAnEventChangesTheVisibleSnapshot() async {
        let original = makeItem(text: "original", age: 1)
        let service = HistoryViewModelRegressionService(items: [original])
        service.suspendNextInitialFetch = true
        let fetchStarted = expectation(description: "Initial snapshot fetch started")
        service.onInitialFetchStarted = { fetchStarted.fulfill() }
        let viewModel = HistoryViewModel(
            service: service,
            settingsViewModel: SettingsViewModel(service: service)
        )
        defer {
            service.resumeInitialFetch()
            viewModel.stop()
        }

        let loadTask = Task { await viewModel.load() }
        await fulfillment(of: [fetchStarted], timeout: 1.0)

        let inserted = makeItem(text: "inserted during load", age: 0)
        service.items.insert(inserted, at: 0)
        await viewModel.handleEvent(.newItem(inserted))
        service.resumeInitialFetch()
        await loadTask.value

        XCTAssertEqual(Set(viewModel.items.map(\.id)), [original.id, inserted.id])
        XCTAssertEqual(service.recentUnpinnedFetchCallCount, 2)
    }

    func testLoadDiscardsASecondStaleSnapshotAndTrailingLoadConverges() async {
        let original = makeItem(text: "original", age: 2)
        let service = HistoryViewModelRegressionService(items: [original])
        let viewModel = HistoryViewModel(
            service: service,
            settingsViewModel: SettingsViewModel(service: service)
        )
        viewModel.configureTiming(.immediateRegressionTests)
        defer {
            service.resumeInitialFetch()
            viewModel.stop()
        }

        service.suspendNextInitialFetch = true
        let firstFetchStarted = expectation(description: "First snapshot fetch started")
        service.onInitialFetchStarted = { firstFetchStarted.fulfill() }
        let initialLoad = Task { await viewModel.load() }
        await fulfillment(of: [firstFetchStarted], timeout: 1.0)

        let firstInserted = makeItem(text: "first concurrent insert", age: 1)
        service.items.insert(firstInserted, at: 0)
        await viewModel.handleEvent(.newItem(firstInserted))

        service.suspendNextInitialFetch = true
        let secondFetchStarted = expectation(description: "Second snapshot fetch started")
        service.onInitialFetchStarted = { secondFetchStarted.fulfill() }
        service.resumeInitialFetch()
        await fulfillment(of: [secondFetchStarted], timeout: 1.0)

        let secondInserted = makeItem(text: "second concurrent insert", age: 0)
        service.items.insert(secondInserted, at: 0)
        await viewModel.handleEvent(.newItem(secondInserted))

        service.suspendNextInitialFetch = true
        let trailingFetchStarted = expectation(description: "Coalesced trailing fetch started")
        service.onInitialFetchStarted = { trailingFetchStarted.fulfill() }
        service.resumeInitialFetch()
        await initialLoad.value
        await fulfillment(of: [trailingFetchStarted], timeout: 1.0)

        XCTAssertTrue(viewModel.items.contains { $0.id == secondInserted.id })
        XCTAssertEqual(service.recentUnpinnedFetchCallCount, 3)

        // Delete while the coalesced snapshot is suspended: cancellation must preserve its
        // target and schedule a replacement, while the late cancelled result stays harmless.
        service.onInitialFetchStarted = nil
        service.items.removeAll { $0.id == firstInserted.id }
        await viewModel.handleEvent(.itemDeleted(firstInserted.id))
        await waitUntil(timeout: 2) {
            service.recentUnpinnedFetchCallCount == 4 && !viewModel.isLoading
                && Set(viewModel.items.map(\.id)) == Set(service.items.map(\.id))
        }
        XCTAssertEqual(service.recentUnpinnedFetchCallCount, 4)
        service.resumeInitialFetch()
        XCTAssertEqual(Set(viewModel.items.map(\.id)), Set(service.items.map(\.id)))
    }

    func testConcurrentLoadMoreCallsShareTheInFlightRequest() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 700))
        let viewModel = HistoryViewModel(
            service: service,
            settingsViewModel: SettingsViewModel(service: service)
        )
        defer {
            service.resumePaginationFetch()
            viewModel.stop()
        }
        await viewModel.load()

        service.suspendNextPaginationFetch = true
        let fetchStarted = expectation(description: "Pagination fetch started")
        service.onPaginationFetchStarted = { fetchStarted.fulfill() }
        let first = Task { await viewModel.loadMore() }
        await fulfillment(of: [fetchStarted], timeout: 1.0)

        let secondStarted = expectation(description: "Second load-more call started")
        let second = Task {
            secondStarted.fulfill()
            await viewModel.loadMore()
        }
        await fulfillment(of: [secondStarted], timeout: 1.0)
        await Task.yield()
        XCTAssertEqual(service.recentUnpinnedFetchCallCount, 2)

        service.resumePaginationFetch()
        await first.value
        await second.value

        XCTAssertEqual(service.recentUnpinnedFetchCallCount, 2)
        XCTAssertEqual(
            viewModel.items.count,
            HistoryViewModel.initialPageSize + HistoryViewModel.loadMorePageSize
        )
    }

    func testRemovingTheSelectedItemClearsSelection() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        let viewModel = HistoryViewModel(
            service: service,
            settingsViewModel: SettingsViewModel(service: service)
        )
        defer { viewModel.stop() }
        await viewModel.load()

        let selectedID = viewModel.items[1].id
        viewModel.selectedID = selectedID
        await viewModel.handleEvent(.itemDeleted(selectedID))

        XCTAssertNil(viewModel.selectedID)
        XCTAssertFalse(viewModel.items.contains { $0.id == selectedID })
    }

    func testSearchPaginationYieldsWithCompleteEvidenceAndPreservesOrderAndSelection() async {
        let results = (0..<(Self.firstTwoPages + 25)).map { makeItem(text: "needle \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: results)
        service.includesMatchEvidence = true
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)
        viewModel.selectedID = results[12].id
        viewModel.scrollDidStart()

        let pagination = Task { await viewModel.loadMore() }
        await waitForNextItemsRevision(in: viewModel)
        XCTAssertGreaterThan(viewModel.loadedCount, 50)
        XCTAssertLessThan(viewModel.loadedCount, Self.firstTwoPages)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.canLoadMore)
        XCTAssertTrue(viewModel.items.allSatisfy { viewModel.searchMatchContext(for: $0.id) != nil })

        // Another caller must await the buffered page rather than fetch overlapping rows.
        await viewModel.loadMore()
        await pagination.value
        XCTAssertEqual(service.searchRequests.map(\.offset), [0, 50])
        XCTAssertEqual(viewModel.items.map(\.id), Array(results.prefix(Self.firstTwoPages)).map(\.id))
        XCTAssertEqual(viewModel.searchMatchContexts.count, Self.firstTwoPages)
        XCTAssertEqual(viewModel.selectedID, results[12].id)
        XCTAssertTrue(viewModel.isScrolling)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.items.map(\.id), results.map(\.id))
        XCTAssertEqual(viewModel.searchMatchContexts.count, results.count)
        XCTAssertEqual(viewModel.totalCount, results.count)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testCalibratedFuzzyPaginationNeverReturnsToPrefilterOrdering() async {
        for mode in [SearchMode.fuzzy, .fuzzyPlus] {
            let results = (0..<(Self.firstTwoPages + 25)).map { makeItem(text: "needle \($0)", age: $0) }
            let service = HistoryViewModelRegressionService(items: results)
            service.includesMatchEvidence = true
            service.returnsStagedFirstPage = true
            service.prefilterItems = Array(results.reversed())
            service.suspendNextRefine = true
            let refineStarted = expectation(description: "Full refine started for \(mode)")
            service.onRefineStarted = { refineStarted.fulfill() }
            let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
            viewModel.configureTiming(.immediateRegressionTests)
            defer { viewModel.stop() }
            viewModel.searchMode = mode
            viewModel.searchQuery = "needle"
            viewModel.search()
            await fulfillment(of: [refineStarted], timeout: 1.0)
            let refined = expectation(description: "Full ranking published for \(mode)")
            withObservationTracking {
                _ = viewModel.searchCoverage
            } onChange: {
                refined.fulfill()
            }
            service.resumeRefine()
            await fulfillment(of: [refined], timeout: 1.0)
            await waitForSearchToFinish(in: viewModel)
            XCTAssertEqual(viewModel.items.map(\.id), Array(results.prefix(50)).map(\.id))

            await viewModel.loadMore()
            XCTAssertEqual(viewModel.searchCoverage, .complete)
            XCTAssertEqual(viewModel.items.map(\.id), Array(results.prefix(Self.firstTwoPages)).map(\.id))
            XCTAssertEqual(Set(viewModel.items.map(\.id)).count, Self.firstTwoPages)
            XCTAssertEqual(viewModel.searchMatchContexts.count, Self.firstTwoPages)
            await viewModel.loadMore()
            XCTAssertEqual(viewModel.items.map(\.id), results.map(\.id))
            XCTAssertEqual(service.searchRequests.map(\.offset), [0, 0, HistoryViewModel.initialPageSize, Self.firstTwoPages])
            XCTAssertTrue(service.searchRequests.dropFirst().allSatisfy(\.forceFullFuzzy))
            XCTAssertFalse(viewModel.canLoadMore)
        }
    }

    func testRefinedPaginationYieldsAndPreservesSelectionMovedIntoTail() async {
        let results = (0..<Self.firstTwoPages).map { makeItem(text: "needle \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: results)
        service.includesMatchEvidence = true
        service.returnsStagedFirstPage = true
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        var timing = HistoryViewModel.Timing.immediateRegressionTests
        timing.refineLongQueryDelayNs = 60_000_000_000
        viewModel.configureTiming(timing)
        defer { viewModel.stop() }
        viewModel.searchMode = .fuzzy
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)
        XCTAssertEqual(viewModel.searchCoverage, .stagedRefine)
        viewModel.selectedID = results[12].id
        viewModel.scrollDidStart()

        // The full search moves the selected row out of the first visible prefix.
        var reordered = results
        let selected = reordered.remove(at: 12)
        reordered.insert(selected, at: 110)
        service.items = reordered
        let pagination = Task { await viewModel.loadMore() }
        await waitForNextItemsRevision(in: viewModel)
        XCTAssertGreaterThan(viewModel.loadedCount, 50)
        XCTAssertLessThan(viewModel.loadedCount, Self.firstTwoPages)
        XCTAssertEqual(viewModel.items.map(\.id), Array(results.prefix(viewModel.loadedCount)).map(\.id))
        XCTAssertEqual(viewModel.searchMatchContexts.count, viewModel.loadedCount)
        XCTAssertEqual(Array(viewModel.items.prefix(50)).map(\.id), Array(results.prefix(50)).map(\.id),
                       "Keep every staged row present so AppKit can preserve the visible scroll anchor")
        await viewModel.selectCurrent()
        XCTAssertEqual(service.copiedItemIDs, [selected.id])
        XCTAssertEqual(viewModel.selectedID, selected.id)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.canLoadMore, "Buffered rows must remain reachable even on the final page")

        await pagination.value
        XCTAssertEqual(service.searchRequests.count, 2)
        XCTAssertEqual(service.searchRequests.last?.offset, 0)
        XCTAssertEqual(service.searchRequests.last?.limit, Self.firstTwoPages)
        XCTAssertTrue(service.searchRequests.last?.forceFullFuzzy == true)
        XCTAssertEqual(viewModel.items.map(\.id), reordered.map(\.id))
        XCTAssertEqual(Set(viewModel.searchMatchContexts.keys), Set(reordered.map(\.id)))
        XCTAssertEqual(viewModel.selectedID, selected.id)
        XCTAssertEqual(viewModel.searchCoverage, .complete)
        XCTAssertTrue(viewModel.isScrolling)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testIdenticalRefinedPrefixUpdatesTotalsWithoutRebuildingRows() async {
        let results = (0..<50).map { makeItem(text: "needle \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: results)
        service.includesMatchEvidence = true
        service.returnsStagedFirstPage = true
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        var timing = HistoryViewModel.Timing.immediateRegressionTests
        timing.refineLongQueryDelayNs = 0
        service.suspendNextRefine = true
        let refineStarted = expectation(description: "Refine started")
        service.onRefineStarted = { refineStarted.fulfill() }
        viewModel.configureTiming(timing)
        defer { viewModel.stop() }
        viewModel.searchMode = .fuzzy
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)
        await fulfillment(of: [refineStarted], timeout: 1.0)
        let revision = viewModel.projectionGeneration
        let refined = expectation(description: "Refine completes")
        withObservationTracking {
            _ = viewModel.searchCoverage
        } onChange: {
            refined.fulfill()
        }
        // What the List body reads: an identical refine that only settles the total must not
        // invalidate it.
        let listInputsInvalidated = expectation(description: "List inputs invalidated")
        listInputsInvalidated.isInverted = true
        withObservationTracking {
            _ = viewModel.pinnedItems
            _ = viewModel.unpinnedItems
            _ = viewModel.canLoadMore
        } onChange: {
            listInputsInvalidated.fulfill()
        }
        service.resumeRefine()
        await fulfillment(of: [refined], timeout: 1.0)
        await fulfillment(of: [listInputsInvalidated], timeout: 0.05)
        XCTAssertEqual(viewModel.projectionGeneration, revision)
        XCTAssertEqual(viewModel.totalCount, 50)
        XCTAssertEqual(viewModel.searchCoverage, .complete)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertEqual(viewModel.searchMatchContexts.count, 50)
    }

    func testChangingSearchDuringPageApplicationDiscardsRemainingRowsAndEvidence() async {
        let oldResults = (0..<(Self.firstTwoPages + 25)).map { makeItem(text: "needle \($0)", age: $0) }
        let newResults = (0..<3).map { makeItem(text: "replacement \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: oldResults + newResults)
        service.includesMatchEvidence = true
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)

        let pagination = Task { await viewModel.loadMore() }
        await waitForNextItemsRevision(in: viewModel)
        XCTAssertGreaterThan(viewModel.loadedCount, 50)
        XCTAssertLessThan(viewModel.loadedCount, Self.firstTwoPages)
        viewModel.searchQuery = "replacement"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)
        await pagination.value

        XCTAssertEqual(viewModel.items.map(\.id), newResults.map(\.id))
        XCTAssertEqual(Set(viewModel.searchMatchContexts.keys), Set(newResults.map(\.id)))
        XCTAssertEqual(viewModel.totalCount, 3)
        XCTAssertEqual(viewModel.searchCoverage, .complete)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testChangingSearchDuringRefinedPaginationDiscardsThePendingRanking() async {
        let oldResults = (0..<(Self.firstTwoPages + 25)).map { makeItem(text: "needle \($0)", age: $0) }
        let newResults = (0..<3).map { makeItem(text: "replacement \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: oldResults + newResults)
        service.includesMatchEvidence = true
        service.returnsStagedFirstPage = true
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        var timing = HistoryViewModel.Timing.immediateRegressionTests
        timing.refineLongQueryDelayNs = 60_000_000_000
        viewModel.configureTiming(timing)
        defer { viewModel.stop() }
        viewModel.searchMode = .fuzzy
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)

        let pagination = Task { await viewModel.loadMore() }
        await waitForNextItemsRevision(in: viewModel)
        XCTAssertGreaterThan(viewModel.loadedCount, 50)
        XCTAssertLessThan(viewModel.loadedCount, Self.firstTwoPages)
        service.returnsStagedFirstPage = false
        viewModel.searchQuery = "replacement"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)
        await pagination.value

        XCTAssertEqual(viewModel.items.map(\.id), newResults.map(\.id))
        XCTAssertEqual(Set(viewModel.searchMatchContexts.keys), Set(newResults.map(\.id)))
        XCTAssertEqual(viewModel.searchCoverage, .complete)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testDeletingBufferedSearchResultCancelsThePageAndCannotResurrectIt() async {
        let results = (0..<(Self.firstTwoPages + 25)).map { makeItem(text: "needle \($0)", age: $0) }
        let service = HistoryViewModelRegressionService(items: results)
        service.includesMatchEvidence = true
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.immediateRegressionTests)
        defer { viewModel.stop() }
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)

        let pagination = Task { await viewModel.loadMore() }
        await waitForNextItemsRevision(in: viewModel)
        let deletedID = results[90].id
        service.items.removeAll { $0.id == deletedID }
        await viewModel.handleEvent(.itemDeleted(deletedID))
        await waitForNextItemsRevision(in: viewModel)
        await waitForSearchToFinish(in: viewModel)
        await pagination.value
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.items.map(\.id), Array(service.items.prefix(Self.firstTwoPages)).map(\.id))
        XCTAssertFalse(viewModel.items.contains { $0.id == deletedID })
        XCTAssertNil(viewModel.searchMatchContext(for: deletedID))
        XCTAssertEqual(viewModel.totalCount, results.count - 1)
    }

    func testSlowDetailedStorageStatsDoesNotBlockFirstScreenLoad() async {
        let service = HistoryViewModelRegressionService(items: makeItems(count: 3))
        service.suspendDetailedStorageStats = true
        let detailedStatsStarted = expectation(description: "Detailed storage stats started")
        service.onDetailedStorageStatsStarted = { detailedStatsStarted.fulfill() }

        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        defer {
            service.resumeDetailedStorageStats()
            viewModel.stop()
        }

        let loadReturned = expectation(description: "First screen load returned")
        let loadTask = Task {
            await viewModel.load()
            loadReturned.fulfill()
        }

        await fulfillment(of: [detailedStatsStarted, loadReturned], timeout: 1.0)
        XCTAssertEqual(viewModel.items.count, 3)
        XCTAssertFalse(viewModel.isLoading)

        let diskSizeUpdated = expectation(description: "Background disk stats applied")
        withObservationTracking {
            _ = settings.diskSizeBytes
        } onChange: {
            diskSizeUpdated.fulfill()
        }
        service.resumeDetailedStorageStats(totalSizeBytes: 4_096)
        await fulfillment(of: [diskSizeUpdated], timeout: 1.0)
        await loadTask.value

        XCTAssertEqual(settings.diskSizeBytes, 4_096)
    }

    private func waitForSearchToFinish(in viewModel: HistoryViewModel) async {
        guard viewModel.isLoading else { return }
        let finished = expectation(description: "Search finished publishing and recording metrics")
        withObservationTracking {
            _ = viewModel.isLoading
        } onChange: {
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1.0)
        XCTAssertFalse(viewModel.isLoading)
    }

    /// The rows loaded after the first page and one load-more page.
    private static let firstTwoPages = HistoryViewModel.initialPageSize + HistoryViewModel.loadMorePageSize

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForNextItemsRevision(in viewModel: HistoryViewModel) async {
        let changed = expectation(description: "History projection changed")
        withObservationTracking {
            _ = viewModel.projectionGeneration
        } onChange: {
            changed.fulfill()
        }
        await fulfillment(of: [changed], timeout: 1.0)
    }

    func testRealHistoryRebasesDuringRecopyAndQuitPersistsDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-history-contract-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "scopy-history-contract-\(UUID())"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let path = root.appendingPathComponent("clipboard.db").path
        let writer = StorageService(databasePath: path)
        try await writer.open()
        for index in 0..<360 {
            _ = try await writer.upsertItem(ClipboardMonitor.ClipboardContent(
                type: .text, plainText: "history contract \(index)", payload: .none,
                appBundleID: nil, contentHash: "history-contract-\(index)", sizeBytes: 20
            ))
        }
        let original = try await writer.fetchRecent(limit: 360, offset: 0)
        let service = ClipboardServiceFactory.create(databasePath: path,
            settingsStore: SettingsStore(suiteName: suite),
            monitorPasteboardName: "scopy-history-contract-\(UUID())", monitorPollingInterval: 60)
        try await service.start()
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.longUndoWindowRegressionTests)
        await viewModel.load()
        XCTAssertEqual(viewModel.items.count, 50)
        let selected = original[10].id
        viewModel.selectedID = selected
        let pagination = Task { await viewModel.loadMore() }
        await waitUntil(timeout: 2) { viewModel.items.count >= 100 }
        let moved = original[300].id
        _ = try await writer.incrementUsage(id: moved, at: Date().addingTimeInterval(1))
        try await service.pin(itemID: original[359].id)
        let newest = try await service.fetchRecent(limit: 2, offset: 0)
        let movedDTO = try XCTUnwrap(newest.first { $0.id == moved })
        await viewModel.handleEvent(.itemUpdated(movedDTO))
        await viewModel.handleEvent(.itemPinned(original[359].id))
        // A delayed duplicate event already represented by the snapshot must not inflate total.
        await viewModel.handleEvent(.newItem(movedDTO))
        await viewModel.handleEvent(.newItem(movedDTO))
        await pagination.value
        await waitUntil(timeout: 3) { !viewModel.isLoading && viewModel.items.count == 351 }
        let prefix = try await service.fetchRecent(limit: 351, offset: 0)
        XCTAssertEqual(viewModel.items.map(\.id), prefix.map(\.id))
        XCTAssertTrue(viewModel.canLoadMore)
        await viewModel.loadMore()
        let authoritative = try await service.fetchRecent(limit: 400, offset: 0)
        XCTAssertEqual(viewModel.items.map(\.id), authoritative.map(\.id))
        XCTAssertEqual(Set(viewModel.items.map(\.id)).count, 360)
        XCTAssertEqual(viewModel.totalCount, 360)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertEqual(viewModel.selectedID, selected)
        let deleted = try XCTUnwrap(viewModel.items.first { $0.id == selected })
        await viewModel.delete(deleted)
        let canQuit = await viewModel.prepareForTermination()
        XCTAssertTrue(canQuit)
        viewModel.stop()
        await service.stopAndWait()
        await writer.close()
        let reopened = StorageService(databasePath: path)
        try await reopened.open()
        let persisted = try await reopened.fetchRecent(limit: 400, offset: 0)
        XCTAssertEqual(persisted.count, 359)
        XCTAssertFalse(persisted.contains { $0.id == selected })
        await reopened.close()
    }

    private func makeItems(count: Int) -> [ClipboardItemDTO] {
        (0..<count).map { makeItem(text: "item \($0)", age: $0) }
    }

    private func makeItem(text: String, age: Int) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: UUID().uuidString,
            plainText: text,
            appBundleID: "com.test.scopy",
            createdAt: Date().addingTimeInterval(TimeInterval(-age)),
            lastUsedAt: Date().addingTimeInterval(TimeInterval(-age)),
            isPinned: false,
            sizeBytes: text.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }
}

private extension HistoryViewModel.Timing {
    static let immediateRegressionTests = HistoryViewModel.Timing(
        searchDebounceNs: 0,
        refineShortQueryDelayNs: 0,
        refineLongQueryDelayNs: 0,
        recentAppsRefreshDelayNs: 0,
        staleLoadRetryDelayNs: 0,
        undoDeletionWindowNs: 50_000_000
    )

    /// The undo window never elapses on its own; a test commits it explicitly.
    static let longUndoWindowRegressionTests = HistoryViewModel.Timing(
        searchDebounceNs: 0,
        refineShortQueryDelayNs: 0,
        refineLongQueryDelayNs: 0,
        recentAppsRefreshDelayNs: 0,
        staleLoadRetryDelayNs: 0,
        undoDeletionWindowNs: 60_000_000_000
    )
}

@MainActor
private final class HistoryViewModelRegressionService: ClipboardServiceProtocol {
    enum TestError: Error {
        case expectedFailure
    }

    var items: [ClipboardItemDTO]
    var deleteShouldFail = false
    var suspendNextDelete = false
    var onDeleteStarted: (() -> Void)?
    private var deleteContinuation: CheckedContinuation<Void, Never>?
    var searchShouldFail = false
    var returnsStagedFirstPage = false
    var prefilterItems: [ClipboardItemDTO]?
    var refineShouldFail = false
    var suspendNextRefine = false
    var suspendDetailedStorageStats = false
    var suspendNextInitialFetch = false
    var suspendNextPaginationFetch = false
    var includesMatchEvidence = false
    var onRefineStarted: (() -> Void)?
    var onDetailedStorageStatsStarted: (() -> Void)?
    var onInitialFetchStarted: (() -> Void)?
    var onPaginationFetchStarted: (() -> Void)?
    private(set) var searchRequests: [SearchRequest] = []
    private(set) var recentUnpinnedFetchCallCount = 0

    private var refineContinuation: CheckedContinuation<Void, Never>?
    private var detailedStorageStatsContinuation: CheckedContinuation<StorageStatsDTO, Never>?
    private var initialFetchContinuation: CheckedContinuation<Void, Never>?
    private var paginationFetchContinuation: CheckedContinuation<Void, Never>?

    init(items: [ClipboardItemDTO]) {
        self.items = items
    }

    var eventStream: AsyncStream<ClipboardEvent> {
        AsyncStream { $0.finish() }
    }

    func start() async throws {}
    func stop() {}
    func stopAndWait() async {}

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        Array(items.dropFirst(offset).prefix(limit))
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        items.filter(\.isPinned)
    }

    func fetchHistoryPage(limit: Int, offset: Int, expectedRevision: Int64?) async throws -> RecentHistoryPage {
        recentUnpinnedFetchCallCount += 1
        let start = expectedRevision == 0 ? max(0, offset) : 0
        let count = max(0, limit) + (start == 0 ? max(0, offset) : 0)
        let pageItems = Array(items.filter { !$0.isPinned }.dropFirst(start).prefix(count))
        let snapshot = RecentHistoryPage(
            pinnedItems: start == 0 ? items.filter(\.isPinned) : [],
            items: pageItems, total: items.count, offset: start,
            nextOffset: start + pageItems.count, revision: 0
        )
        if offset == 0, suspendNextInitialFetch {
            suspendNextInitialFetch = false
            await withCheckedContinuation { continuation in
                initialFetchContinuation = continuation
                onInitialFetchStarted?()
            }
        } else if offset > 0, suspendNextPaginationFetch {
            suspendNextPaginationFetch = false
            await withCheckedContinuation { continuation in
                paginationFetchContinuation = continuation
                onPaginationFetchStarted?()
            }
        }
        return snapshot
    }

    func resumeInitialFetch() {
        initialFetchContinuation?.resume()
        initialFetchContinuation = nil
    }

    func resumePaginationFetch() {
        paginationFetchContinuation?.resume()
        paginationFetchContinuation = nil
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        searchRequests.append(query)
        if searchShouldFail {
            throw TestError.expectedFailure
        }
        if query.forceFullFuzzy, refineShouldFail {
            await withCheckedContinuation { continuation in
                refineContinuation = continuation
                onRefineStarted?()
            }
            throw TestError.expectedFailure
        }

        if query.forceFullFuzzy, suspendNextRefine {
            suspendNextRefine = false
            await withCheckedContinuation { continuation in
                refineContinuation = continuation
                onRefineStarted?()
            }
        }
        let isStaged = returnsStagedFirstPage && !query.forceFullFuzzy
        let searchItems = isStaged ? (prefilterItems ?? items) : items
        let matches = searchItems.filter {
            query.query.isEmpty || $0.plainText.localizedCaseInsensitiveContains(query.query)
        }
        let start = min(query.offset, matches.count)
        let end = min(start + query.limit, matches.count)
        return SearchResultPage(
            hits: matches[start..<end].map { item in
                let context: SearchMatchContext? = includesMatchEvidence ? SearchMatchContext(
                    mode: query.mode,
                    fragments: [SearchMatchFragment(
                        source: .content,
                        text: item.plainText,
                        highlightedRanges: [SearchMatchTextRange(offset: 0, length: query.query.count)]
                    )],
                    occurrenceCount: 1,
                    occurrenceCountIsTruncated: false,
                    isPositionOnly: false
                ) : nil
                return SearchResultHit(item: item, matchContext: context)
            },
            total: isStaged ? -1 : matches.count,
            hasMore: end < matches.count,
            coverage: isStaged ? .stagedRefine : .complete
        )
    }

    func resumeRefine() {
        refineContinuation?.resume()
        refineContinuation = nil
    }

    func pin(itemID: UUID) async throws {}
    func unpin(itemID: UUID) async throws {}
    func updateNote(itemID: UUID, note: String?) async throws {}

    func delete(itemID: UUID) async throws {
        if deleteShouldFail {
            throw TestError.expectedFailure
        }
        if suspendNextDelete {
            suspendNextDelete = false
            await withCheckedContinuation { continuation in
                deleteContinuation = continuation
                onDeleteStarted?()
            }
        }
        items.removeAll { $0.id == itemID }
    }

    func resumeDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }

    func clearAll() async throws {
        items.removeAll { !$0.isPinned }
    }

    var copiedItemIDs: [UUID] = []
    func copyToClipboard(itemID: UUID) async throws { copiedItemIDs.append(itemID) }
    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {}
    func fileURLs(itemID: UUID) async throws -> [URL] { [] }
    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
        SettingsDTO.default.applying(patch)
    }
    func getSettings() async throws -> SettingsDTO { .default }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        (items.count, items.reduce(0) { $0 + $1.sizeBytes })
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        guard suspendDetailedStorageStats else {
            return makeStorageStats(totalSizeBytes: 0)
        }
        return await withCheckedContinuation { continuation in
            detailedStorageStatsContinuation = continuation
            onDetailedStorageStatsStarted?()
        }
    }

    func resumeDetailedStorageStats(totalSizeBytes: Int = 0) {
        detailedStorageStatsContinuation?.resume(
            returning: makeStorageStats(totalSizeBytes: totalSizeBytes)
        )
        detailedStorageStatsContinuation = nil
        suspendDetailedStorageStats = false
    }

    func getImageData(itemID: UUID) async throws -> Data? { nil }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
    }

    func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }
    func getRecentApps(limit: Int) async throws -> [String] { [] }

    private func makeStorageStats(totalSizeBytes: Int) -> StorageStatsDTO {
        StorageStatsDTO(
            itemCount: items.count,
            databaseSizeBytes: totalSizeBytes,
            externalStorageSizeBytes: 0,
            thumbnailSizeBytes: 0,
            totalSizeBytes: totalSizeBytes,
            databasePath: "/tmp/scopy-regression.sqlite"
        )
    }
}
