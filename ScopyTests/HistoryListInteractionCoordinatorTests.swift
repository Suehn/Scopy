import XCTest

@testable import Scopy

@MainActor
final class HistoryListInteractionCoordinatorTests: XCTestCase {
    func testScrollLifecycleNotifiesObserversAndAppliesCooldown() async throws {
        let coordinator = HistoryListInteractionCoordinator()
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

        try await Task.sleep(nanoseconds: 300_000_000)
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

        observation = nil

        coordinator.beginScrolling()
        coordinator.endScrolling()

        XCTAssertTrue(events.isEmpty)
    }
}
