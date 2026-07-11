import CoreGraphics
import XCTest

@MainActor
final class ListLiveScrollObserverIntegrationUITests: XCTestCase {
    private enum AccessibilityID {
        static let harness = "UITest.ListLiveScrollObserverHarness"
        static let verticalScroller = "UITest.ListLiveScrollObserverHarness.VerticalScroller"
        static let horizontalScroller = "UITest.ListLiveScrollObserverHarness.HorizontalScroller"
        static let observerAttached = "UITest.ListLiveScrollObserverHarness.ObserverAttached"
        static let pointerStartCount = "UITest.ListLiveScrollObserverHarness.PointerStartCount"
        static let pointerEndCount = "UITest.ListLiveScrollObserverHarness.PointerEndCount"
        static let pointerActiveCount = "UITest.ListLiveScrollObserverHarness.PointerActiveCount"
    }

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--list-live-scroll-observer-harness"]
        app.launchEnvironment["SCOPY_UITEST_LIST_LIVE_SCROLL_OBSERVER_HARNESS"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testRealVerticalAndHorizontalScrollerMousePairing() throws {
        XCTAssertTrue(
            app.anyElement(AccessibilityID.harness).waitForExistence(timeout: 10)
        )
        waitForValue(
            "attached=1",
            identifier: AccessibilityID.observerAttached
        )
        waitForValue(
            "start=0",
            identifier: AccessibilityID.pointerStartCount
        )
        waitForValue(
            "end=0",
            identifier: AccessibilityID.pointerEndCount
        )
        waitForValue(
            "active=0",
            identifier: AccessibilityID.pointerActiveCount
        )

        dragRealScroller(
            identifier: AccessibilityID.verticalScroller,
            axis: .vertical
        )
        waitForPointerCounts(start: 1, end: 1)

        dragRealScroller(
            identifier: AccessibilityID.horizontalScroller,
            axis: .horizontal
        )
        waitForPointerCounts(start: 2, end: 2)
    }

    private enum Axis {
        case vertical
        case horizontal
    }

    private func dragRealScroller(identifier: String, axis: Axis) {
        let scroller = app.anyElement(identifier)
        XCTAssertTrue(scroller.waitForExistence(timeout: 5), "Missing real scroller: \(identifier)")
        XCTAssertFalse(scroller.frame.isEmpty, "Real scroller has no screen geometry: \(identifier)")
        switch axis {
        case .vertical:
            XCTAssertGreaterThan(scroller.frame.height, scroller.frame.width)
        case .horizontal:
            XCTAssertGreaterThan(scroller.frame.width, scroller.frame.height)
        }

        let start = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endOffset: CGVector
        switch axis {
        case .vertical:
            endOffset = CGVector(dx: 0.5, dy: 0.72)
        case .horizontal:
            endOffset = CGVector(dx: 0.72, dy: 0.5)
        }
        let end = scroller.coordinate(withNormalizedOffset: endOffset)
        // Legacy horizontal NSScroller accessibility can report `isHittable == false` despite a
        // valid on-screen frame. XCUICoordinate still targets that real AppKit element directly.
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func waitForPointerCounts(start: Int, end: Int) {
        waitForValue(
            "start=\(start)",
            identifier: AccessibilityID.pointerStartCount
        )
        waitForValue(
            "end=\(end)",
            identifier: AccessibilityID.pointerEndCount
        )
        waitForValue(
            "active=0",
            identifier: AccessibilityID.pointerActiveCount
        )
    }

    private func waitForValue(
        _ expected: String,
        identifier: String,
        timeout: TimeInterval = 5
    ) {
        let element = app.anyElement(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing counter: \(identifier)")
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected \(identifier) to become \(expected)")
    }
}
