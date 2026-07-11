import XCTest

@testable import Scopy

@MainActor
final class HistoryListInteractionCoordinatorTests: XCTestCase {
    @MainActor
    private final class ManualCooldownScheduler {
        private final class Entry {
            let deadline: CFTimeInterval
            let action: HistoryListInteractionCoordinator.CooldownAction
            var isCancelled = false

            init(
                deadline: CFTimeInterval,
                action: @escaping HistoryListInteractionCoordinator.CooldownAction
            ) {
                self.deadline = deadline
                self.action = action
            }
        }

        var now: CFTimeInterval = 100
        private var entries: [Entry] = []

        func schedule(
            delay: CFTimeInterval,
            action: @escaping HistoryListInteractionCoordinator.CooldownAction
        ) -> HistoryListInteractionCoordinator.CooldownCancellation {
            let entry = Entry(deadline: now + delay, action: action)
            entries.append(entry)
            return HistoryListInteractionCoordinator.CooldownCancellation {
                entry.isCancelled = true
            }
        }

        func advance(by interval: CFTimeInterval) {
            now += interval
            let due = entries.filter { $0.deadline <= now }
            entries.removeAll { $0.deadline <= now }
            for entry in due where !entry.isCancelled {
                entry.action()
            }
        }
    }

    func testScrollLifecycleNotifiesObserversAndAppliesCooldown() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        var events: [HistoryListInteractionCoordinator.Event] = []

        let observation = coordinator.observe { events.append($0) }

        XCTAssertFalse(coordinator.isScrolling)
        XCTAssertFalse(coordinator.isHoverPreviewSuppressed)

        coordinator.beginScrolling()

        XCTAssertTrue(coordinator.isScrolling)
        XCTAssertTrue(coordinator.isHoverPreviewSuppressed)
        XCTAssertEqual(events, [.scrollStarted])

        coordinator.endScrolling()

        XCTAssertFalse(coordinator.isScrolling)
        XCTAssertTrue(coordinator.isHoverPreviewSuppressed)
        XCTAssertEqual(events, [.scrollStarted, .scrollEnded])

        scheduler.advance(by: 0.25)
        XCTAssertFalse(coordinator.isHoverPreviewSuppressed)

        observation.cancel()
    }

    func testPointerInteractionSuppressesPreviewWithoutChangingScrollState() {
        let coordinator = HistoryListInteractionCoordinator()
        var events: [HistoryListInteractionCoordinator.Event] = []

        let observation = coordinator.observe { events.append($0) }

        coordinator.beginPointerInteraction()

        XCTAssertFalse(coordinator.isScrolling)
        XCTAssertTrue(coordinator.isPointerInteractionActive)
        XCTAssertTrue(coordinator.isHoverPreviewSuppressed)
        XCTAssertEqual(events, [.pointerInteractionStarted])

        coordinator.endPointerInteraction()

        XCTAssertFalse(coordinator.isPointerInteractionActive)
        XCTAssertFalse(coordinator.isHoverPreviewSuppressed)
        XCTAssertEqual(events, [.pointerInteractionStarted, .pointerInteractionEnded])

        observation.cancel()
    }

    func testActiveSlotReplacementRejectsStaleAThenBReleasesAfterAReclaims() {
        let coordinator = HistoryListInteractionCoordinator()
        let firstA = coordinator.makePassiveRowToken()
        let rowB = coordinator.makePassiveRowToken()
        let secondA = coordinator.makePassiveRowToken()

        XCTAssertTrue(coordinator.claimActiveRow(token: firstA, onEvent: { _ in }, restore: {}))
        XCTAssertTrue(coordinator.claimActiveRow(token: rowB, onEvent: { _ in }, restore: {}))

        coordinator.releaseActiveRow(token: firstA)
        XCTAssertTrue(coordinator.ownsActiveRow(token: rowB))

        XCTAssertTrue(coordinator.claimActiveRow(token: secondA, onEvent: { _ in }, restore: {}))
        coordinator.releaseActiveRow(token: rowB)
        coordinator.releaseActiveRow(token: firstA)

        XCTAssertTrue(coordinator.ownsActiveRow(token: secondA))
        XCTAssertEqual(coordinator.passivePathSnapshot.activeRowCount, 1)

        coordinator.releaseActiveRow(token: secondA)
        XCTAssertEqual(coordinator.passivePathSnapshot.activeRowCount, 0)
    }

    func testSuppressedCandidateReplacementRejectsLateAAndBClears() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let firstA = coordinator.makePassiveRowToken()
        let rowB = coordinator.makePassiveRowToken()
        let secondA = coordinator.makePassiveRowToken()
        var restored: [String] = []

        coordinator.beginScrolling()
        XCTAssertTrue(coordinator.setSuppressedHoverCandidate(token: firstA) {
            restored.append("first-a")
        })
        XCTAssertTrue(coordinator.setSuppressedHoverCandidate(token: rowB) {
            restored.append("b")
        })
        XCTAssertTrue(coordinator.setSuppressedHoverCandidate(token: secondA) {
            restored.append("second-a")
        })

        coordinator.clearSuppressedHoverCandidate(token: firstA)
        coordinator.clearSuppressedHoverCandidate(token: rowB)
        XCTAssertTrue(coordinator.ownsSuppressedHoverCandidate(token: secondA))
        XCTAssertEqual(coordinator.passivePathSnapshot.suppressedHoverCandidateCount, 1)

        coordinator.endScrolling()
        scheduler.advance(by: 0.25)

        XCTAssertEqual(restored, ["second-a"])
        XCTAssertEqual(coordinator.passivePathSnapshot.suppressedHoverCandidateCount, 0)
    }

    func testStationaryActiveRowRestoresOnceAfterCooldownWithoutAnotherHoverEvent() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let token = coordinator.makePassiveRowToken()
        var suppressionEvents: [HistoryListInteractionCoordinator.Event] = []
        var restoreCount = 0

        XCTAssertTrue(coordinator.claimActiveRow(
            token: token,
            onEvent: { suppressionEvents.append($0) },
            restore: { restoreCount += 1 }
        ))

        coordinator.beginScrolling()
        coordinator.endScrolling()

        XCTAssertEqual(suppressionEvents, [.scrollStarted])
        XCTAssertFalse(coordinator.ownsActiveRow(token: token))
        XCTAssertTrue(coordinator.ownsSuppressedHoverCandidate(token: token))
        XCTAssertEqual(coordinator.passivePathSnapshot.cooldownTaskCount, 1)

        scheduler.advance(by: 0.249)
        XCTAssertEqual(restoreCount, 0)
        XCTAssertTrue(coordinator.isHoverPreviewSuppressed)

        scheduler.advance(by: 0.001)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(coordinator.isHoverPreviewSuppressed)
        XCTAssertEqual(coordinator.passivePathSnapshot.cooldownTaskCount, 0)

        scheduler.advance(by: 1)
        XCTAssertEqual(restoreCount, 1)
    }

    func testCandidateReplacementDuringCooldownCancelsOldRestoration() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let rowA = coordinator.makePassiveRowToken()
        let rowB = coordinator.makePassiveRowToken()
        var restored: [String] = []

        XCTAssertTrue(coordinator.claimActiveRow(
            token: rowA,
            onEvent: { _ in },
            restore: { restored.append("a") }
        ))
        coordinator.beginScrolling()
        coordinator.endScrolling()

        scheduler.advance(by: 0.1)
        XCTAssertTrue(coordinator.setSuppressedHoverCandidate(token: rowB) {
            restored.append("b")
        })
        coordinator.clearSuppressedHoverCandidate(token: rowA)

        scheduler.advance(by: 0.149)
        XCTAssertTrue(restored.isEmpty)
        scheduler.advance(by: 0.001)

        XCTAssertEqual(restored, ["b"])
        XCTAssertEqual(coordinator.passivePathSnapshot.cooldownTaskCount, 0)
    }

    func testNewScrollInvalidatesPreviousCooldownGeneration() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let token = coordinator.makePassiveRowToken()
        var restoreCount = 0

        XCTAssertTrue(coordinator.claimActiveRow(
            token: token,
            onEvent: { _ in },
            restore: { restoreCount += 1 }
        ))
        coordinator.beginScrolling()
        coordinator.endScrolling()

        scheduler.advance(by: 0.1)
        coordinator.beginScrolling()
        scheduler.advance(by: 0.2)
        XCTAssertEqual(restoreCount, 0)

        coordinator.endScrolling()
        scheduler.advance(by: 0.25)
        XCTAssertEqual(restoreCount, 1)
    }

    func testScrollPointerOverlapRestoresOnlyAfterBothReasonsAndCooldownEnd() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let row = coordinator.makePassiveRowToken()
        var restoreCount = 0

        XCTAssertTrue(coordinator.claimActiveRow(
            token: row,
            onEvent: { _ in },
            restore: { restoreCount += 1 }
        ))
        coordinator.beginScrolling()
        let pointerToken = coordinator.beginPointerInteraction()
        coordinator.endScrolling()

        scheduler.advance(by: 0.25)
        XCTAssertEqual(restoreCount, 0)
        XCTAssertTrue(coordinator.isPointerInteractionActive)

        coordinator.endPointerInteraction(token: pointerToken)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertFalse(coordinator.isHoverPreviewSuppressed)
    }

    func testStalePointerTokenCannotEndReplacementSession() {
        let coordinator = HistoryListInteractionCoordinator()
        let first = coordinator.beginPointerInteraction()
        let second = coordinator.beginPointerInteraction()

        coordinator.endPointerInteraction(token: first)
        XCTAssertTrue(coordinator.isPointerInteractionActive)
        XCTAssertEqual(coordinator.passivePathSnapshot.pointerInteractionCount, 1)

        coordinator.endPointerInteraction(token: second)
        XCTAssertFalse(coordinator.isPointerInteractionActive)
        XCTAssertEqual(coordinator.passivePathSnapshot.pointerInteractionCount, 0)
    }

    func testPassivePathTeardownCancelsScheduledRestore() {
        let scheduler = ManualCooldownScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let token = coordinator.makePassiveRowToken()
        var restoreCount = 0

        XCTAssertTrue(coordinator.claimActiveRow(
            token: token,
            onEvent: { _ in },
            restore: { restoreCount += 1 }
        ))
        coordinator.beginScrolling()
        coordinator.endScrolling()
        XCTAssertEqual(coordinator.passivePathSnapshot.cooldownTaskCount, 1)

        coordinator.tearDownPassivePath()
        scheduler.advance(by: 1)

        XCTAssertEqual(restoreCount, 0)
        XCTAssertEqual(
            coordinator.passivePathSnapshot,
            HistoryListInteractionCoordinator.PassivePathSnapshot(
                activeRowCount: 0,
                suppressedHoverCandidateCount: 0,
                cooldownTaskCount: 0,
                pointerInteractionCount: 0,
                cooldownGeneration: coordinator.passivePathSnapshot.cooldownGeneration
            )
        )
    }

    func testPassivePathSnapshotSinkPublishesEveryOwnershipTransition() {
        let scheduler = ManualCooldownScheduler()
        var snapshots: [HistoryListInteractionCoordinator.PassivePathSnapshot] = []
        let coordinator = HistoryListInteractionCoordinator(
            monotonicNow: { scheduler.now },
            scheduleCooldown: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            passivePathSnapshotSink: { snapshots.append($0) }
        )
        let token = coordinator.makePassiveRowToken()

        XCTAssertEqual(snapshots.last?.activeRowCount, 0)
        XCTAssertEqual(snapshots.last?.suppressedHoverCandidateCount, 0)
        XCTAssertTrue(coordinator.claimActiveRow(token: token, onEvent: { _ in }, restore: {}))
        XCTAssertEqual(snapshots.last?.activeRowCount, 1)
        XCTAssertEqual(snapshots.last?.suppressedHoverCandidateCount, 0)

        coordinator.beginScrolling()
        XCTAssertTrue(
            snapshots.contains {
                $0.activeRowCount == 1 && $0.suppressedHoverCandidateCount == 1
            }
        )
        XCTAssertEqual(snapshots.last?.activeRowCount, 0)
        XCTAssertEqual(snapshots.last?.suppressedHoverCandidateCount, 1)

        coordinator.clearSuppressedHoverCandidate(token: token)
        XCTAssertEqual(snapshots.last?.activeRowCount, 0)
        XCTAssertEqual(snapshots.last?.suppressedHoverCandidateCount, 0)
        XCTAssertTrue(snapshots.allSatisfy { (0...1).contains($0.activeRowCount) })
        XCTAssertTrue(
            snapshots.allSatisfy { (0...1).contains($0.suppressedHoverCandidateCount) }
        )
    }

    func testCancelledObservationStopsFurtherCallbacks() {
        let coordinator = HistoryListInteractionCoordinator()
        var events: [HistoryListInteractionCoordinator.Event] = []

        let observation = coordinator.observe { events.append($0) }
        observation.cancel()

        coordinator.beginScrolling()
        coordinator.endScrolling()

        XCTAssertTrue(events.isEmpty)
    }

    func testObservationDeinitStopsFurtherCallbacks() {
        let coordinator = HistoryListInteractionCoordinator()
        var events: [HistoryListInteractionCoordinator.Event] = []
        var observation: HistoryListInteractionObservation? = coordinator.observe { events.append($0) }

        XCTAssertNotNil(observation)
        observation = nil

        coordinator.beginScrolling()
        coordinator.endScrolling()

        XCTAssertTrue(events.isEmpty)
    }

    func testLegacyObservationCanCancelItselfReentrantly() {
        let coordinator = HistoryListInteractionCoordinator()
        var callbackCount = 0
        var observation: HistoryListInteractionObservation?
        observation = coordinator.observe { _ in
            callbackCount += 1
            observation?.cancel()
        }

        coordinator.beginScrolling()
        coordinator.endScrolling()

        XCTAssertEqual(callbackCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testHoverPreviewTransferBlocksOtherRowsUntilOwnerEnds() {
        let coordinator = HistoryListInteractionCoordinator()
        let sourceItemID = UUID()
        let adjacentItemID = UUID()
        var events: [HistoryListInteractionCoordinator.Event] = []
        let observation = coordinator.observe { events.append($0) }

        XCTAssertTrue(coordinator.beginHoverPreviewTransfer(for: sourceItemID))
        XCTAssertEqual(coordinator.hoverPreviewTransferOwnerID, sourceItemID)
        XCTAssertFalse(coordinator.isHoverPreviewTransferBlocked(for: sourceItemID))
        XCTAssertTrue(coordinator.isHoverPreviewTransferBlocked(for: adjacentItemID))
        XCTAssertFalse(coordinator.beginHoverPreviewTransfer(for: adjacentItemID))

        coordinator.endHoverPreviewTransfer(for: adjacentItemID)
        XCTAssertEqual(coordinator.hoverPreviewTransferOwnerID, sourceItemID)
        XCTAssertTrue(events.isEmpty)

        coordinator.endHoverPreviewTransfer(for: sourceItemID)
        XCTAssertNil(coordinator.hoverPreviewTransferOwnerID)
        XCTAssertEqual(events, [.hoverPreviewTransferEnded(itemID: sourceItemID)])

        observation.cancel()
    }

    func testHoverPreviewTransferEndTargetsSolePassiveActiveRow() {
        let coordinator = HistoryListInteractionCoordinator()
        let sourceItemID = UUID()
        let activeRow = coordinator.makePassiveRowToken()
        var passiveEvents: [HistoryListInteractionCoordinator.Event] = []
        var legacyEvents: [HistoryListInteractionCoordinator.Event] = []
        let observation = coordinator.observe { legacyEvents.append($0) }

        XCTAssertTrue(coordinator.claimActiveRow(
            token: activeRow,
            onEvent: { passiveEvents.append($0) },
            restore: {}
        ))
        XCTAssertTrue(coordinator.beginHoverPreviewTransfer(for: sourceItemID))

        coordinator.endHoverPreviewTransfer(for: sourceItemID)

        let expected = HistoryListInteractionCoordinator.Event.hoverPreviewTransferEnded(
            itemID: sourceItemID
        )
        XCTAssertEqual(passiveEvents, [expected])
        XCTAssertEqual(legacyEvents, [expected])
        XCTAssertTrue(coordinator.ownsActiveRow(token: activeRow))

        observation.cancel()
    }

    func testHoverPreviewTransferEndTargetsNewestPassiveActiveRowOnly() {
        let coordinator = HistoryListInteractionCoordinator()
        let sourceItemID = UUID()
        let staleRow = coordinator.makePassiveRowToken()
        let currentRow = coordinator.makePassiveRowToken()
        var staleEventCount = 0
        var currentEvents: [HistoryListInteractionCoordinator.Event] = []

        XCTAssertTrue(coordinator.claimActiveRow(
            token: staleRow,
            onEvent: { _ in staleEventCount += 1 },
            restore: {}
        ))
        XCTAssertTrue(coordinator.claimActiveRow(
            token: currentRow,
            onEvent: { currentEvents.append($0) },
            restore: {}
        ))
        XCTAssertTrue(coordinator.beginHoverPreviewTransfer(for: sourceItemID))

        coordinator.endHoverPreviewTransfer(for: sourceItemID)

        XCTAssertEqual(staleEventCount, 0)
        XCTAssertEqual(
            currentEvents,
            [.hoverPreviewTransferEnded(itemID: sourceItemID)]
        )
        XCTAssertEqual(coordinator.passivePathSnapshot.activeRowCount, 1)
    }

    func testStaleHoverTransferTokenCannotEndNewerSameRowTransfer() {
        let coordinator = HistoryListInteractionCoordinator()
        let itemID = UUID()

        let first = tryUnwrap(coordinator.beginHoverPreviewTransferToken(for: itemID))
        coordinator.endHoverPreviewTransfer(token: first)
        let second = tryUnwrap(coordinator.beginHoverPreviewTransferToken(for: itemID))

        coordinator.endHoverPreviewTransfer(token: first)
        XCTAssertEqual(coordinator.hoverPreviewTransferOwnerID, itemID)

        coordinator.endHoverPreviewTransfer(token: second)
        XCTAssertNil(coordinator.hoverPreviewTransferOwnerID)
    }

    private func makeCoordinator(
        scheduler: ManualCooldownScheduler
    ) -> HistoryListInteractionCoordinator {
        HistoryListInteractionCoordinator(
            monotonicNow: { scheduler.now },
            scheduleCooldown: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            }
        )
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
