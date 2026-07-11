import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryContentRevisionRegistryTests: XCTestCase {
    func testProjectionReplacementDoesNotInvalidateKnownRevision() async {
        let service = TestMockClipboardService()
        service.setItemCount(3)
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }
        await appState.load()

        let target = appState.items[0]
        let targetRevision = ClipboardItemContentRevision(item: target)
        XCTAssertTrue(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: targetRevision
            )
        )

        appState.items = [appState.items[1]]

        XCTAssertFalse(appState.items.contains { $0.id == target.id })
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
        defer { appState.stop() }
        await appState.load()

        let target = appState.items[0]
        let oldRevision = ClipboardItemContentRevision(item: target)
        appState.items = [appState.items[1]]
        let updated = replacingContent(of: target, hash: "updated-hash", text: "updated")
        let updatedRevision = ClipboardItemContentRevision(item: updated)
        let oldToken = appState.historyViewModel.contentRevisionReconciliationToken

        await appState.historyViewModel.handleEvent(.itemContentUpdated(updated))

        XCTAssertFalse(appState.items.contains { $0.id == target.id })
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
        defer { appState.stop() }
        await appState.load()

        let target = try! XCTUnwrap(appState.items.first)
        let revision = ClipboardItemContentRevision(item: target)

        await appState.historyViewModel.handleEvent(.itemDeleted(target.id))
        appState.items = [target]

        XCTAssertTrue(appState.items.isEmpty, "A stale search/load projection must not revive a deleted row")
        XCTAssertFalse(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: revision
            )
        )
        XCTAssertTrue(
            appState.historyViewModel.contentRevisionReconciliationSnapshot.wasDeleted(target.id)
        )

        await appState.historyViewModel.handleEvent(.newItem(target))

        XCTAssertEqual(appState.items.map(\.id), [target.id])
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
        defer { appState.stop() }
        await appState.load()

        let target = try! XCTUnwrap(appState.items.first)
        service.resetSearchCallCount()
        service.searchDelayIgnoresCancellation = true
        service.searchDelayNs = 200_000_000
        appState.searchQuery = "Test"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchStartedQueries.count == 1
        })

        try! await service.delete(itemID: target.id)
        service.searchDelayNs = 0
        await appState.historyViewModel.handleEvent(.itemDeleted(target.id))

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchStartedQueries.count == 2 && service.searchCallCount >= 1
        }, message: "An authoritative delete should replace the in-flight filtered projection")
        XCTAssertFalse(appState.items.contains { $0.id == target.id })

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 2
        }, message: "The uncancellable stale request should finish without overwriting the refresh")
        XCTAssertFalse(appState.items.contains { $0.id == target.id })
    }

    func testItemsClearedDuringActiveSearchEmptiesProjectionAndInvalidatesOldRevision() async {
        let service = TestMockClipboardService()
        service.setItemCount(10)
        let appState = AppState.forTesting(service: service, historyTiming: .production)
        defer { appState.stop() }
        await appState.load()

        let target = try! XCTUnwrap(appState.items.first)
        let revision = ClipboardItemContentRevision(item: target)
        appState.searchQuery = "Test"
        appState.search()
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 1 && !appState.isLoading
        })

        service.setItemCount(0)
        await appState.historyViewModel.handleEvent(.itemsCleared(keepPinned: false))

        XCTAssertTrue(appState.items.isEmpty)
        XCTAssertEqual(appState.totalCount, 0)
        XCTAssertFalse(
            appState.historyViewModel.isContentRevisionCurrent(
                itemID: target.id,
                revision: revision
            )
        )
        XCTAssertGreaterThan(
            appState.historyViewModel.contentRevisionReconciliationSnapshot.clearGeneration,
            0
        )
    }

    func testClearAllKeepsPinnedDraftButInvalidatesUnpinnedDraft() async {
        let service = TestMockClipboardService()
        service.setItemCount(2, pinnedCount: 1)
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }
        await appState.load()

        let pinnedItem = try! XCTUnwrap(appState.pinnedItems.first)
        let unpinnedItem = try! XCTUnwrap(appState.unpinnedItems.first)
        let pinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: pinnedItem),
            relativeTimeText: "now"
        )
        let unpinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: unpinnedItem),
            relativeTimeText: "now"
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

        await appState.clearAll()
        store.reconcile(
            snapshot: appState.historyViewModel.contentRevisionReconciliationSnapshot
        )

        XCTAssertTrue(store.contains(pinnedState))
        XCTAssertFalse(pinnedState.isTornDown)
        XCTAssertEqual(pinnedState.rowController.noteDraft, "pinned draft")
        XCTAssertFalse(store.contains(unpinnedState))
        XCTAssertTrue(unpinnedState.isTornDown)
        XCTAssertEqual(appState.items.map(\.id), [pinnedItem.id])
    }

    func testTransientPinnedFetchFailureDoesNotEraseKnownPinnedDraft() async {
        let service = TestMockClipboardService()
        service.setItemCount(2, pinnedCount: 1)
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }
        await appState.load()

        let pinnedItem = try! XCTUnwrap(appState.pinnedItems.first)
        let unpinnedItem = try! XCTUnwrap(appState.unpinnedItems.first)
        let pinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: pinnedItem),
            relativeTimeText: "now"
        )
        let unpinnedState = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: unpinnedItem),
            relativeTimeText: "now"
        )
        pinnedState.rowController.presentNoteEditor(note: "pinned draft survives read failure")
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
        service.fetchPinnedFailuresRemaining = 1
        await appState.historyViewModel.handleEvent(.itemsCleared(keepPinned: true))
        let snapshot = appState.historyViewModel.contentRevisionReconciliationSnapshot
        store.reconcile(snapshot: snapshot)

        XCTAssertFalse(snapshot.clearSurvivorSetIsAuthoritative)
        XCTAssertTrue(snapshot.clearSurvivingItemIDs.contains(pinnedItem.id))
        XCTAssertTrue(store.contains(pinnedState))
        XCTAssertFalse(pinnedState.isTornDown)
        XCTAssertEqual(
            pinnedState.rowController.noteDraft,
            "pinned draft survives read failure"
        )
        XCTAssertFalse(store.contains(unpinnedState))
        XCTAssertTrue(unpinnedState.isTornDown)
        XCTAssertEqual(appState.items.map(\.id), [pinnedItem.id])
    }

    func testRegistryIsBoundedAndCapacityEvictionRemainsUnknown() {
        let service = TestMockClipboardService()
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }
        let itemCount = HistoryViewModel.knownContentRevisionCapacity + 4
        let items = (0..<itemCount).map { index in makeItem(index: index) }
        let evictedItem = items[0]
        let evictedRevision = ClipboardItemContentRevision(item: evictedItem)

        appState.items = items

        let snapshot = appState.historyViewModel.contentRevisionReconciliationSnapshot
        XCTAssertLessThanOrEqual(
            snapshot.knownRevisionsByItemID.count,
            HistoryViewModel.knownContentRevisionCapacity
        )
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
            revision: evictedRevision,
            relativeTimeText: "now"
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

    func testDeletionTombstoneEvictionConservativelyInvalidatesRetainedSessions() {
        let items = (0..<3).map { index in makeItem(index: index) }
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 2)
        _ = registry.merge(items: items, allowRevivingDeletedItems: false)
        let state = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: items[0]),
            relativeTimeText: "now"
        )
        state.rowController.presentNoteEditor(note: "must not survive a lost tombstone")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))
        store.reconcile(snapshot: registry.snapshot)

        for item in items {
            _ = registry.invalidate(itemID: item.id)
        }
        let overflowedSnapshot = registry.snapshot

        XCTAssertEqual(overflowedSnapshot.deletedItemIDs.count, 2)
        XCTAssertGreaterThan(overflowedSnapshot.deletionEvictionGeneration, 0)
        store.reconcile(snapshot: overflowedSnapshot)
        XCTAssertTrue(state.isTornDown)
        XCTAssertFalse(store.contains(state))
    }

    func testTombstoneOverflowStillAcceptsLegitimateUnknownProjection() {
        let deletedItems = (0..<2).map { index in makeItem(index: index) }
        let legitimateProjectionItem = makeItem(index: 3)
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 1)

        for item in deletedItems {
            _ = registry.invalidate(itemID: item.id)
        }
        XCTAssertGreaterThan(registry.snapshot.deletionEvictionGeneration, 0)

        _ = registry.merge(
            items: [legitimateProjectionItem],
            allowRevivingDeletedItems: false
        )

        XCTAssertEqual(
            registry.snapshot.revision(for: legitimateProjectionItem.id),
            ClipboardItemContentRevision(item: legitimateProjectionItem)
        )
    }

    func testCapacityEvictedUnpinnedSessionIsInvalidatedByKeepPinnedClear() {
        let unpinnedItem = makeItem(index: 1)
        let pinnedItem = makeItem(index: 2).withPinned(true)
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 1)
        _ = registry.merge(
            items: [unpinnedItem, pinnedItem],
            allowRevivingDeletedItems: false
        )
        XCTAssertNil(registry.snapshot.revision(for: unpinnedItem.id))

        let state = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: unpinnedItem),
            relativeTimeText: "now"
        )
        state.rowController.presentNoteEditor(note: "evicted unpinned draft")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))
        store.reconcile(snapshot: registry.snapshot)

        registry.clear(survivingPinnedItems: [pinnedItem])
        store.reconcile(snapshot: registry.snapshot)

        XCTAssertTrue(state.isTornDown)
        XCTAssertFalse(store.contains(state))
    }

    func testCapacityEvictedPinnedSessionSurvivesAuthoritativeKeepPinnedClear() {
        let firstPinnedItem = makeItem(index: 1).withPinned(true)
        let secondPinnedItem = makeItem(index: 2).withPinned(true)
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 1)
        _ = registry.merge(
            items: [firstPinnedItem, secondPinnedItem],
            allowRevivingDeletedItems: false
        )
        XCTAssertNil(registry.snapshot.revision(for: firstPinnedItem.id))

        let state = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: firstPinnedItem),
            relativeTimeText: "now"
        )
        state.rowController.presentNoteEditor(note: "capacity-evicted pinned draft")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))
        store.reconcile(snapshot: registry.snapshot)

        registry.clear(survivingPinnedItems: [firstPinnedItem, secondPinnedItem])
        let clearSnapshot = registry.snapshot
        XCTAssertLessThanOrEqual(clearSnapshot.knownRevisionsByItemID.count, 1)
        XCTAssertTrue(clearSnapshot.clearSurvivingItemIDs.contains(firstPinnedItem.id))

        store.reconcile(snapshot: clearSnapshot)

        XCTAssertTrue(store.contains(state))
        XCTAssertFalse(state.isTornDown)
        XCTAssertEqual(state.rowController.noteDraft, "capacity-evicted pinned draft")
    }

    func testCapacityUnknownSessionSurvivesNonAuthoritativePinnedClear() {
        let capacityEvictedPinnedItem = makeItem(index: 1).withPinned(true)
        let retainedPinnedItem = makeItem(index: 2).withPinned(true)
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 1)
        _ = registry.merge(
            items: [capacityEvictedPinnedItem, retainedPinnedItem],
            allowRevivingDeletedItems: false
        )
        XCTAssertNil(registry.snapshot.revision(for: capacityEvictedPinnedItem.id))

        let state = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: capacityEvictedPinnedItem),
            relativeTimeText: "now"
        )
        state.rowController.presentNoteEditor(note: "unknown pinned draft")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))

        registry.clear(
            survivingPinnedItems: [],
            survivorSetIsAuthoritative: false
        )
        let snapshot = registry.snapshot
        store.reconcile(snapshot: snapshot)

        XCTAssertFalse(snapshot.clearSurvivorSetIsAuthoritative)
        XCTAssertTrue(store.contains(state))
        XCTAssertFalse(state.isTornDown)
        XCTAssertEqual(state.rowController.noteDraft, "unknown pinned draft")
    }

    func testPinThenClearPreservesSessionAndUnpinThenClearInvalidatesIt() {
        let item = makeItem(index: 3)
        let pinnedItem = item.withPinned(true)
        var registry = BoundedHistoryContentRevisionRegistry(capacity: 2)
        _ = registry.merge(items: [item], allowRevivingDeletedItems: false)
        XCTAssertTrue(registry.setPinned(itemID: item.id, isPinned: true))

        let state = HistoryItemInteractionState(
            revision: ClipboardItemContentRevision(item: item),
            relativeTimeText: "now"
        )
        state.rowController.presentNoteEditor(note: "pinned draft")
        let store = HistoryItemInteractionSessionStore()
        let attachment = store.makeAttachmentToken()
        state.activateViewAttachment(attachment)
        XCTAssertTrue(store.registerExplicitWork(state, attachmentToken: attachment))
        store.reconcile(snapshot: registry.snapshot)

        registry.clear(survivingPinnedItems: [pinnedItem])
        store.reconcile(snapshot: registry.snapshot)
        XCTAssertTrue(store.contains(state))
        XCTAssertEqual(state.rowController.noteDraft, "pinned draft")

        XCTAssertTrue(registry.setPinned(itemID: item.id, isPinned: false))
        registry.clear(survivingPinnedItems: [])
        store.reconcile(snapshot: registry.snapshot)
        XCTAssertTrue(state.isTornDown)
        XCTAssertFalse(store.contains(state))
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
            _ = registry.merge(items: [item], allowRevivingDeletedItems: false)
        }

        for _ in 0..<100 {
            _ = registry.invalidate(itemID: item.id)
            _ = registry.merge(items: [item], allowRevivingDeletedItems: true)
        }

        let queueCounts = registry.testingQueueCounts
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
            storageRef: item.storageRef
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
            storageRef: nil
        )
    }
}
