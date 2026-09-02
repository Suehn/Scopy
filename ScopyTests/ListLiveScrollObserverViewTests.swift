import AppKit
import XCTest

@MainActor
final class ListLiveScrollObserverViewTests: XCTestCase {
    private final class FlippedRootView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class PartReportingScroller: NSScroller {
        var reportedPart: NSScroller.Part = .knobSlot

        override func testPart(_ point: NSPoint) -> NSScroller.Part {
            reportedPart
        }
    }

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let verticalScroller: PartReportingScroller
        let horizontalScroller: PartReportingScroller
        let coordinator: HistoryListInteractionCoordinator
        let observer: ListLiveScrollObserverView.ObserverView

        init(attachObserver: Bool = false) {
            let frame = NSRect(x: 0, y: 0, width: 240, height: 180)
            window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            // Match the flipped NSHostingView used by the real SwiftUI hierarchy. This catches
            // accidental conversion of window points into content-view-local coordinates before
            // calling NSView.hitTest(_:).
            let rootView = FlippedRootView(frame: frame)
            window.contentView = rootView

            scrollView = NSScrollView(frame: rootView.bounds)
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.documentView = NSView(
                frame: NSRect(x: 0, y: 0, width: 480, height: 360)
            )

            verticalScroller = PartReportingScroller(
                frame: NSRect(x: 224, y: 16, width: 16, height: 164)
            )
            horizontalScroller = PartReportingScroller(
                frame: NSRect(x: 0, y: 0, width: 224, height: 16)
            )
            scrollView.verticalScroller = verticalScroller
            scrollView.horizontalScroller = horizontalScroller
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true

            rootView.addSubview(scrollView)
            scrollView.tile()

            // Keep the fixture geometry independent of the host's preferred scroller style.
            verticalScroller.frame = NSRect(x: 224, y: 16, width: 16, height: 164)
            horizontalScroller.frame = NSRect(x: 0, y: 0, width: 224, height: 16)
            for scroller in [verticalScroller, horizontalScroller] {
                scroller.isEnabled = true
                scroller.isHidden = false
                scroller.alphaValue = 1
                scroller.reportedPart = .knobSlot
            }

            coordinator = HistoryListInteractionCoordinator()
            observer = ListLiveScrollObserverView.ObserverView(frame: .zero)
            observer.interactionCoordinator = coordinator
            // Tests move the clip view programmatically; treat that as wheel-driven unless a test
            // says otherwise.
            observer.isScrollWheelInputCurrent = { true }
            if attachObserver {
                scrollView.contentView.addSubview(observer)
                observer.attachIfNeeded()
            }
        }

        func pointInWindow(for view: NSView) -> NSPoint {
            view.convert(
                NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                to: nil
            )
        }

        func contentPointInWindow() -> NSPoint {
            guard let documentView = scrollView.documentView else { return .zero }
            return documentView.convert(NSPoint(x: 24, y: 24), to: nil)
        }

        func detachObserver() {
            observer.removeFromSuperview()
        }
    }

    func testActionableVerticalAndHorizontalScrollersAreClassified() {
        let fixture = Fixture()
        let location = NSPoint(x: 91, y: 47)
        var testedScroller: NSScroller?
        var testedPoint: NSPoint?

        let verticalAxis = ListLiveScrollObserverView.ObserverView.scrollbarAxis(
            in: fixture.scrollView,
            eventWindow: fixture.window,
            locationInWindow: location,
            hitView: fixture.verticalScroller,
            testPart: { scroller, point in
                testedScroller = scroller
                testedPoint = point
                return .knobSlot
            }
        )

        XCTAssertEqual(verticalAxis, .vertical)
        XCTAssertTrue(testedScroller === fixture.verticalScroller)
        XCTAssertEqual(
            testedPoint,
            location,
            "NSScroller.testPart receives the event point in window coordinates"
        )

        let horizontalAxis = ListLiveScrollObserverView.ObserverView.scrollbarAxis(
            in: fixture.scrollView,
            eventWindow: fixture.window,
            locationInWindow: location,
            hitView: fixture.horizontalScroller,
            testPart: { _, _ in .knobSlot }
        )

        XCTAssertEqual(horizontalAxis, .horizontal)
    }

    func testOrdinaryContentAndNoPartAreRejected() throws {
        let fixture = Fixture()
        let documentView = try XCTUnwrap(fixture.scrollView.documentView)
        var partResolverWasCalled = false

        let contentAxis = ListLiveScrollObserverView.ObserverView.scrollbarAxis(
            in: fixture.scrollView,
            eventWindow: fixture.window,
            locationInWindow: .zero,
            hitView: documentView,
            testPart: { _, _ in
                partResolverWasCalled = true
                return .knobSlot
            }
        )

        XCTAssertNil(contentAxis)
        XCTAssertFalse(partResolverWasCalled)

        let noPartAxis = ListLiveScrollObserverView.ObserverView.scrollbarAxis(
            in: fixture.scrollView,
            eventWindow: fixture.window,
            locationInWindow: .zero,
            hitView: fixture.verticalScroller,
            testPart: { _, _ in .noPart }
        )

        XCTAssertNil(noPartAxis)
    }

    func testHiddenDetachedDisabledAndFadedScrollersAreRejected() {
        assertVerticalScrollerIsRejected { $0.isHidden = true }
        assertVerticalScrollerIsRejected { $0.isEnabled = false }
        assertVerticalScrollerIsRejected { $0.alphaValue = 0 }
        assertVerticalScrollerIsRejected { $0.superview?.alphaValue = 0 }
        assertVerticalScrollerIsRejected { $0.removeFromSuperview() }

        let notInstalledFixture = Fixture()
        notInstalledFixture.scrollView.hasVerticalScroller = false
        XCTAssertNil(classifyVerticalScroller(in: notInstalledFixture))
    }

    func testScrollerInAnotherWindowIsRejected() {
        let fixture = Fixture()
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        let axis = ListLiveScrollObserverView.ObserverView.scrollbarAxis(
            in: fixture.scrollView,
            eventWindow: otherWindow,
            locationInWindow: .zero,
            hitView: fixture.verticalScroller,
            testPart: { _, _ in .knobSlot }
        )

        XCTAssertNil(axis)
    }

    func testOrdinaryContentDownAndUnmatchedMouseUpDoNotBeginOrEndSuppression() {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        var events: [HistoryListInteractionCoordinator.Event] = []
        let observation = fixture.coordinator.observe { events.append($0) }
        defer { observation.cancel() }

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.contentPointInWindow()
        )
        fixture.observer.handlePointerInteraction(
            type: .leftMouseUp,
            eventWindow: fixture.window,
            locationInWindow: fixture.contentPointInWindow()
        )

        XCTAssertFalse(fixture.coordinator.isPointerInteractionActive)
        XCTAssertTrue(events.isEmpty)
    }

    func testScrollerDownAndMouseUpPairOneOwnedPointerInteraction() {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.pressedMouseButtonsProvider = { 1 }
        var events: [HistoryListInteractionCoordinator.Event] = []
        let observation = fixture.coordinator.observe { events.append($0) }
        defer { observation.cancel() }
        let scrollerPoint = fixture.pointInWindow(for: fixture.verticalScroller)

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: scrollerPoint
        )

        XCTAssertTrue(fixture.coordinator.isPointerInteractionActive)
        XCTAssertEqual(events, [.pointerInteractionStarted])

        // The matching up may occur away from the scroller; only the owned down matters.
        fixture.observer.handlePointerInteraction(
            type: .leftMouseUp,
            eventWindow: nil,
            locationInWindow: NSPoint(x: -100, y: -100)
        )

        XCTAssertFalse(fixture.coordinator.isPointerInteractionActive)
        XCTAssertEqual(events, [.pointerInteractionStarted, .pointerInteractionEnded])
    }

    func testDetachEndsOwnedPointerInteractionExactlyOnce() {
        let fixture = Fixture(attachObserver: true)
        fixture.observer.pressedMouseButtonsProvider = { 1 }
        var events: [HistoryListInteractionCoordinator.Event] = []
        let observation = fixture.coordinator.observe { events.append($0) }
        defer { observation.cancel() }

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.pointInWindow(for: fixture.verticalScroller)
        )
        XCTAssertTrue(fixture.coordinator.isPointerInteractionActive)

        fixture.detachObserver()
        fixture.detachObserver()

        XCTAssertFalse(fixture.coordinator.isPointerInteractionActive)
        XCTAssertEqual(events, [.pointerInteractionStarted, .pointerInteractionEnded])
    }

    func testLiveScrollEndCleansConsumedMouseUpWithoutStartNotification() {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.pressedMouseButtonsProvider = { 0 }
        var events: [HistoryListInteractionCoordinator.Event] = []
        let observation = fixture.coordinator.observe { events.append($0) }
        defer { observation.cancel() }

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.pointInWindow(for: fixture.verticalScroller)
        )
        XCTAssertTrue(fixture.coordinator.isPointerInteractionActive)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: fixture.scrollView
        )

        XCTAssertFalse(fixture.coordinator.isPointerInteractionActive)
        XCTAssertEqual(events, [.pointerInteractionStarted, .pointerInteractionEnded])
    }

    func testLiveScrollEndKeepsPointerReasonWhilePhysicalButtonRemainsDown() {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.pressedMouseButtonsProvider = { 1 }

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.pointInWindow(for: fixture.verticalScroller)
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: fixture.scrollView
        )

        XCTAssertTrue(fixture.coordinator.isPointerInteractionActive)

        fixture.observer.handlePointerInteraction(
            type: .leftMouseUp,
            eventWindow: fixture.window,
            locationInWindow: fixture.contentPointInWindow()
        )
        XCTAssertFalse(fixture.coordinator.isPointerInteractionActive)
    }

    func testPostDispatchFallbackCleansConsumedMouseUp() async {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.pressedMouseButtonsProvider = { 0 }
        var events: [HistoryListInteractionCoordinator.Event] = []
        let ended = expectation(description: "consumed mouse-up fallback ended ownership")
        let observation = fixture.coordinator.observe { event in
            events.append(event)
            if event == .pointerInteractionEnded {
                ended.fulfill()
            }
        }
        defer { observation.cancel() }

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.pointInWindow(for: fixture.horizontalScroller)
        )
        XCTAssertTrue(fixture.coordinator.isPointerInteractionActive)

        await fulfillment(of: [ended], timeout: 1)

        XCTAssertFalse(fixture.coordinator.isPointerInteractionActive)
        XCTAssertEqual(events, [.pointerInteractionStarted, .pointerInteractionEnded])
    }

    private func scrollClipView(_ fixture: Fixture, toY y: CGFloat) {
        let clipView = fixture.scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: y))
        fixture.scrollView.reflectScrolledClipView(clipView)
    }

    private func waitForBoundsSettle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        // The settle work item is queued on the main queue; let it run.
        await Task.yield()
    }

    func testClipViewMovementReportsOneScrollThatEndsAfterSettle() async {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.boundsSettleInterval = 0.05
        var starts = 0
        var ends = 0
        fixture.observer.onScrollStart = { starts += 1 }
        fixture.observer.onScrollEnd = { ends += 1 }

        XCTAssertTrue(fixture.scrollView.contentView.postsBoundsChangedNotifications)
        scrollClipView(fixture, toY: 24)
        scrollClipView(fixture, toY: 48)
        scrollClipView(fixture, toY: 72)

        XCTAssertTrue(fixture.observer.isScrollingReported)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 0)

        await waitForBoundsSettle(0.2)

        XCTAssertFalse(fixture.observer.isScrollingReported)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
    }

    func testLiveScrollEndWaitsForClipViewToSettle() async {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.boundsSettleInterval = 0.05
        fixture.observer.pressedMouseButtonsProvider = { 0 }
        var starts = 0
        var ends = 0
        fixture.observer.onScrollStart = { starts += 1 }
        fixture.observer.onScrollEnd = { ends += 1 }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: fixture.scrollView
        )
        scrollClipView(fixture, toY: 24)
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: fixture.scrollView
        )
        // Momentum keeps the clip view moving after the gesture ended.
        scrollClipView(fixture, toY: 48)

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 0)
        XCTAssertTrue(fixture.observer.isScrollingReported)

        await waitForBoundsSettle(0.2)

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(fixture.observer.isScrollingReported)
    }

    func testProgrammaticScrollGateHidesClipViewMovement() async {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.boundsSettleInterval = 0.05
        var now: CFTimeInterval = 100
        let gate = ListProgrammaticScrollGate(now: { now })
        fixture.observer.programmaticScrollGate = gate
        var starts = 0
        fixture.observer.onScrollStart = { starts += 1 }

        gate.beginProgrammaticScroll(duration: 0.35)
        XCTAssertTrue(gate.isProgrammaticScrollActive)
        scrollClipView(fixture, toY: 24)
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(fixture.observer.isScrollingReported)

        now += 0.4
        XCTAssertFalse(gate.isProgrammaticScrollActive)
        scrollClipView(fixture, toY: 48)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(fixture.observer.isScrollingReported)
        await waitForBoundsSettle(0.2)
        XCTAssertFalse(fixture.observer.isScrollingReported)
    }

    func testClipViewMovementWithoutScrollWheelInputIsLayoutNotScrolling() async {
        let fixture = Fixture(attachObserver: true)
        defer { fixture.detachObserver() }
        fixture.observer.boundsSettleInterval = 0.05
        fixture.observer.isScrollWheelInputCurrent = { false }
        var starts = 0
        fixture.observer.onScrollStart = { starts += 1 }

        scrollClipView(fixture, toY: 24)
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(fixture.observer.isScrollingReported)

        // A live-scroll gesture in progress still lets clip-view movement extend the scroll.
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: fixture.scrollView
        )
        scrollClipView(fixture, toY: 48)
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: fixture.scrollView
        )
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(fixture.observer.isScrollingReported)
        await waitForBoundsSettle(0.2)
        XCTAssertFalse(fixture.observer.isScrollingReported)
    }

    func testDetachWhileClipViewScrollingReportsEndOnce() {
        let fixture = Fixture(attachObserver: true)
        fixture.observer.boundsSettleInterval = 10
        var ends = 0
        fixture.observer.onScrollEnd = { ends += 1 }

        scrollClipView(fixture, toY: 24)
        XCTAssertTrue(fixture.observer.isScrollingReported)

        fixture.detachObserver()
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(fixture.observer.isScrollingReported)
    }

    func testWindowResolverDoesNotReuseDetachedCachedListScrollView() throws {
        let frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let rootView = NSView(frame: frame)
        window.contentView = rootView

        func makeListScrollView() -> NSScrollView {
            let scrollView = NSScrollView(frame: rootView.bounds)
            scrollView.documentView = NSTableView(
                frame: NSRect(x: 0, y: 0, width: 480, height: 360)
            )
            return scrollView
        }

        let first = makeListScrollView()
        rootView.addSubview(first)
        let observer = ListLiveScrollObserverView.ObserverView(frame: .zero)
        observer.interactionCoordinator = HistoryListInteractionCoordinator()

        var attachments: [NSScrollView] = []
        observer.onScrollViewAttach = { attachments.append($0) }
        rootView.addSubview(observer)
        observer.attachIfNeeded()
        XCTAssertTrue(try XCTUnwrap(attachments.last) === first)

        // Keep `first` strongly alive after removing it, mirroring a recycled SwiftUI host whose
        // AppKit subtree has not deallocated yet. The resolver must still leave the stale cache.
        first.removeFromSuperview()
        let replacement = makeListScrollView()
        rootView.addSubview(replacement, positioned: .below, relativeTo: observer)
        observer.attachIfNeeded()

        XCTAssertEqual(attachments.count, 2)
        XCTAssertTrue(try XCTUnwrap(attachments.last) === replacement)
        observer.removeFromSuperview()
    }

    private func assertVerticalScrollerIsRejected(
        after mutation: (PartReportingScroller) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fixture = Fixture()
        mutation(fixture.verticalScroller)
        XCTAssertNil(classifyVerticalScroller(in: fixture), file: file, line: line)
    }

    private func classifyVerticalScroller(
        in fixture: Fixture
    ) -> ListLiveScrollObserverView.ObserverView.ScrollbarAxis? {
        ListLiveScrollObserverView.ObserverView.scrollbarAxis(
            in: fixture.scrollView,
            eventWindow: fixture.window,
            locationInWindow: .zero,
            hitView: fixture.verticalScroller,
            testPart: { _, _ in .knobSlot }
        )
    }
}
