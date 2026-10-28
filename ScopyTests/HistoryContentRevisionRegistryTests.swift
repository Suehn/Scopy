import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryContentRevisionRegistryTests: XCTestCase {
    func testProjectionReplacementDoesNotInvalidateKnownRevision() async {
        let service = TestMockClipboardService()
        service.setItemCount(3)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        await appState.historyViewModel.load()

        let target = appState.historyViewModel.items[0]
        let targetRevision = ClipboardItemContentRevision(item: target)
        XCTAssertTrue(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: targetRevision
            )
        )

        appState.historyViewModel.replaceItemsForTesting([appState.historyViewModel.items[1]])

        XCTAssertFalse(appState.historyViewModel.items.contains { $0.id == target.id })
        XCTAssertTrue(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: targetRevision
            ),
            "Search/filter/page projections must not be interpreted as authoritative deletion"
        )
    }

    func testOffscreenContentUpdateAdvancesAuthoritativeRevision() async {
        let service = TestMockClipboardService()
        service.setItemCount(2)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        await appState.historyViewModel.load()

        let target = appState.historyViewModel.items[0]
        let oldRevision = ClipboardItemContentRevision(item: target)
        appState.historyViewModel.replaceItemsForTesting([appState.historyViewModel.items[1]])
        let updated = replacingContent(of: target, hash: "updated-hash", text: "updated")
        let updatedRevision = ClipboardItemContentRevision(item: updated)
        let oldToken = appState.historyViewModel.contentRevisionReconciliationToken

        await appState.historyViewModel.handleEvent(service.historyEvent(.itemsChanged([updated], kind: .content)))

        XCTAssertFalse(appState.historyViewModel.items.contains { $0.id == target.id })
        XCTAssertFalse(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: oldRevision
            )
        )
        XCTAssertTrue(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: updatedRevision
            )
        )
        XCTAssertGreaterThan(
            appState.historyViewModel.contentRevisionReconciliationToken,
            oldToken
        )
    }

    func testDeleteTombstoneRejectsStaleProjectionUntilExplicitNewItem() async {
        let service = TestMockClipboardService()
        service.setItemCount(1)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        await appState.historyViewModel.load()

        let target = try! XCTUnwrap(appState.historyViewModel.items.first)
        let revision = ClipboardItemContentRevision(item: target)

        await appState.historyViewModel.handleEvent(service.historyEvent(.itemsRemoved([target.id])))
        appState.historyViewModel.replaceItemsForTesting([target])

        XCTAssertTrue(appState.historyViewModel.items.isEmpty, "A stale search/load projection must not revive a deleted row")
        XCTAssertFalse(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: revision
            )
        )
        XCTAssertTrue(
            appState.historyViewModel.contentRevisionReconciliationSnapshot.wasDeleted(target.id)
        )

        await appState.historyViewModel.handleEvent(service.historyEvent(.itemsChanged([target], kind: .inserted)))

        XCTAssertEqual(appState.historyViewModel.items.map(\.id), [target.id])
        XCTAssertTrue(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: revision
            )
        )
        XCTAssertFalse(
            appState.historyViewModel.contentRevisionReconciliationSnapshot.wasDeleted(target.id)
        )
    }

    func testDeleteInvalidatesInFlightSearchAndRefreshesActiveProjection() async {
        let service = TestMockClipboardService()
        service.setItemCount(3)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        await appState.historyViewModel.load()

        let target = try! XCTUnwrap(appState.historyViewModel.items.first)
        service.resetSearchCallCount()
        service.searchDelayIgnoresCancellation = true
        service.searchDelayNs = 200_000_000
        appState.historyViewModel.searchQuery = "Test"
        appState.historyViewModel.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchStartedQueries.count == 1
        })

        _ = try! await service.delete(itemID: target.id, expectedUseCount: target.useCount)
        service.searchDelayNs = 0
        await appState.historyViewModel.handleEvent(service.historyEvent(.itemsRemoved([target.id])))

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchStartedQueries.count == 2 && service.searchCallCount >= 1
        }, message: "An authoritative delete should replace the in-flight filtered projection")
        XCTAssertFalse(appState.historyViewModel.items.contains { $0.id == target.id })

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 2
        }, message: "The uncancellable stale request should finish without overwriting the refresh")
        XCTAssertFalse(appState.historyViewModel.items.contains { $0.id == target.id })
    }

    func testItemsClearedDuringActiveSearchEmptiesProjectionAndInvalidatesOldRevision() async {
        let service = TestMockClipboardService()
        service.setItemCount(10)
        let appState = AppState.forTesting(service: service, historyTiming: .production)
        addTeardownBlock {
            await appState.stop()
        }
        await appState.historyViewModel.load()

        let target = try! XCTUnwrap(appState.historyViewModel.items.first)
        let revision = ClipboardItemContentRevision(item: target)
        appState.historyViewModel.searchQuery = "Test"
        appState.historyViewModel.search()
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 1 && !appState.historyViewModel.isLoading
        })

        let removedIDs = appState.historyViewModel.items.map(\.id)
        service.setItemCount(0)
        await appState.historyViewModel.handleEvent(service.historyEvent(.itemsCleared(deletedItemIDs: removedIDs)))

        XCTAssertTrue(appState.historyViewModel.items.isEmpty)
        XCTAssertEqual(appState.historyViewModel.totalCount, 0)
        XCTAssertFalse(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: revision
            )
        )
        XCTAssertTrue(appState.historyViewModel.contentRevisionReconciliationSnapshot.wasDeleted(target.id))
    }

    func testClearAllKeepsPinnedDraftButInvalidatesUnpinnedDraft() async {
        let service = TestMockClipboardService()
        service.setItemCount(2, pinnedCount: 1)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        let subscribed = expectation(description: "Event listener subscribed")
        service.onEventStreamSubscribed = { subscribed.fulfill() }
        await appState.start()
        await fulfillment(of: [subscribed], timeout: 1.0)

        let pinnedItem = try! XCTUnwrap(appState.historyViewModel.pinnedItems.first)
        let unpinnedItem = try! XCTUnwrap(appState.historyViewModel.unpinnedItems.first)
        let pinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: pinnedItem)
        )
        let unpinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: unpinnedItem)
        )
        pinnedState.rowController.presentNoteEditor(note: "pinned draft")
        unpinnedState.rowController.presentNoteEditor(note: "unpinned draft")
        let store = HistoryItemInteractionSessionStore()
        let pinnedAttachment = store.makeAttachmentToken()
        let unpinnedAttachment = store.makeAttachmentToken()
        pinnedState.activateViewAttachment(pinnedAttachment)
        unpinnedState.activateViewAttachment(unpinnedAttachment)
        XCTAssertTrue(store.registerExplicitWork(pinnedState, attachmentToken: pinnedAttachment))
        XCTAssertTrue(store.registerExplicitWork(unpinnedState, attachmentToken: unpinnedAttachment))
        store.reconcile(
            snapshot: appState.historyViewModel.contentRevisionReconciliationSnapshot
        )

        let clearHandled = expectation(description: "Clear event handled before sentinel")
        appState.applyHotKeyHandler = { _, _ in
            clearHandled.fulfill()
            return true
        }
        await appState.historyViewModel.clearAll()
        service.emitEvent(.settingsChanged)
        await fulfillment(of: [clearHandled], timeout: 1.0)
        store.reconcile(
            snapshot: appState.historyViewModel.contentRevisionReconciliationSnapshot
        )

        XCTAssertTrue(store.contains(pinnedState))
        XCTAssertFalse(pinnedState.isTornDown)
        XCTAssertEqual(pinnedState.rowController.noteDraft, "pinned draft")
        XCTAssertFalse(store.contains(unpinnedState))
        XCTAssertTrue(unpinnedState.isTornDown)
        XCTAssertEqual(appState.historyViewModel.items.map(\.id), [pinnedItem.id])
    }

    func testClearPreservesPinnedDraftWithoutReadingSurvivors() async {
        let service = TestMockClipboardService()
        service.setItemCount(2, pinnedCount: 1)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        await appState.historyViewModel.load()

        let pinnedItem = try! XCTUnwrap(appState.historyViewModel.pinnedItems.first)
        let unpinnedItem = try! XCTUnwrap(appState.historyViewModel.unpinnedItems.first)
        let pinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: pinnedItem)
        )
        let unpinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: unpinnedItem)
        )
        pinnedState.rowController.presentNoteEditor(note: "pinned draft survives exact clear")
        unpinnedState.rowController.presentNoteEditor(note: "deleted unpinned draft")
        let store = HistoryItemInteractionSessionStore()
        let pinnedAttachment = store.makeAttachmentToken()
        let unpinnedAttachment = store.makeAttachmentToken()
        pinnedState.activateViewAttachment(pinnedAttachment)
        unpinnedState.activateViewAttachment(unpinnedAttachment)
        XCTAssertTrue(store.registerExplicitWork(pinnedState, attachmentToken: pinnedAttachment))
        XCTAssertTrue(store.registerExplicitWork(unpinnedState, attachmentToken: unpinnedAttachment))
        store.reconcile(snapshot: appState.historyViewModel.contentRevisionReconciliationSnapshot)

        try! await service.clearAll()
        await appState.historyViewModel.handleEvent(service.historyEvent(.itemsCleared(deletedItemIDs: [unpinnedItem.id])))
        let snapshot = appState.historyViewModel.contentRevisionReconciliationSnapshot
        store.reconcile(snapshot: snapshot)

        XCTAssertTrue(store.contains(pinnedState))
        XCTAssertFalse(pinnedState.isTornDown)
        XCTAssertEqual(
            pinnedState.rowController.noteDraft,
            "pinned draft survives exact clear"
        )
        XCTAssertFalse(store.contains(unpinnedState))
        XCTAssertTrue(unpinnedState.isTornDown)
        XCTAssertEqual(appState.historyViewModel.items.map(\.id), [pinnedItem.id])
    }

    func testUnversionedProjectionDoesNotClaimRegistryAuthority() {
        let service = TestMockClipboardService()
        let appState = AppState.forTesting(service: service)
        addTeardownBlock {
            await appState.stop()
        }
        let itemCount = HistoryViewModel.knownContentRevisionCapacity + 4
        let items = (0..<itemCount).map { index in makeItem(index: index) }
        let evictedItem = items[0]
        let evictedRevision = ClipboardItemContentRevision(item: evictedItem)

        appState.historyViewModel.replaceItemsForTesting(items)

        let snapshot = appState.historyViewModel.contentRevisionReconciliationSnapshot
        XCTAssertTrue(snapshot.knownRevisionsByItemID.isEmpty)
        XCTAssertNil(snapshot.revision(for: evictedItem.id))
        XCTAssertFalse(snapshot.wasDeleted(evictedItem.id))
        XCTAssertTrue(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: evictedItem.id,
                revision: evictedRevision
            ),
            "The O(1) loaded projection remains authoritative after bounded registry eviction"
        )

        let interactionState = HistoryItemInteractionState(
            revision: evictedRevision
        )
        interactionState.rowController.presentNoteEditor(note: "retained")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        interactionState.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(interactionState, attachmentToken: attachment))

        store.reconcile(snapshot: snapshot)

        XCTAssertTrue(store.contains(interactionState))
        XCTAssertFalse(interactionState.isTornDown)
    }

    func testProtectedHolderKeepsItsDeletionThroughTombstoneEviction() {
        let items = (0..<3).map { index in makeItem(index: index) }
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 2)
        _ = registry.merge(items: items, mutationSeq: 0)
        let state = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: items[0])
        )
        state.rowController.presentNoteEditor(note: "must not survive a lost tombstone")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))
        store.reconcile(snapshot: registry.snapshot)

        registry.protect(itemIDs: [state.itemID])
        for item in items {
            _ = registry.invalidate(itemID: item.id, mutationSeq: 1)
        }
        _ = registry.invalidate(itemID: UUID(), mutationSeq: 2)
        let overflowedSnapshot = registry.snapshot

        XCTAssertLessThanOrEqual(overflowedSnapshot.deletedItemIDs.count, 3)
        XCTAssertTrue(overflowedSnapshot.wasDeleted(state.itemID))
        store.reconcile(snapshot: overflowedSnapshot)
        XCTAssertTrue(state.isTornDown)
        XCTAssertFalse(store.contains(state))
    }

    func testTombstoneOverflowStillAcceptsLegitimateUnknownProjection() {
        let deletedItems = (0..<2).map { index in makeItem(index: index) }
        let legitimateProjectionItem = makeItem(index: 3)
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 1)

        for item in deletedItems {
            _ = registry.invalidate(itemID: item.id, mutationSeq: 1)
        }

        _ = registry.merge(
            items: [legitimateProjectionItem],
            mutationSeq: 3
        )

        XCTAssertEqual(
            registry.snapshot.revision(for: legitimateProjectionItem.id),
            ClipboardItemContentRevision(item: legitimateProjectionItem)
        )
    }

    func testRegistryQueuesStayBoundedUnderSameIDRevisionAndDeleteReviveChurn() {
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 2)
        var item = makeItem(index: 9)

        for revisionIndex in 0..<100 {
            item = replacingContent(
                of: item,
                hash: "churn-\(revisionIndex)",
                text: "churn-\(revisionIndex)"
            )
            _ = registry.merge(items: [item], mutationSeq: Int64(revisionIndex))
        }

        for index in 0..<100 {
            _ = registry.invalidate(itemID: item.id, mutationSeq: Int64(100 + index * 2))
            _ = registry.merge(items: [item], mutationSeq: Int64(101 + index * 2))
        }

        let queueCounts = registry.queueCountsForTesting
        XCTAssertLessThanOrEqual(queueCounts.revision, 8)
        XCTAssertLessThanOrEqual(queueCounts.deletion, 8)
    }

    private func replacingContent(
        of item: ClipboardItemDTO,
        hash: String,
        text: String
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: hash,
            plainText: text,
            note: item.note,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes + 1,
            fileSizeBytes: item.fileSizeBytes,
            thumbnailPath: item.thumbnailPath,
            storageRef: item.storageRef,
            useCount: item.useCount
        )
    }

    private func makeItem(index: Int) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: "hash-\(index)",
            plainText: "item-\(index)",
            note: nil,
            appBundleID: "com.scopy.tests",
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            lastUsedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            isPinned: false,
            sizeBytes: index + 1,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil,
            useCount: 1
        )
    }
}
