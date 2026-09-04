import AppKit
import XCTest

/// The history panel closes when focus leaves it. Pinning a preview opens a second Scopy window,
/// and clicking or dragging that window must not take the panel down with it — while every other
/// way of losing key focus has to keep behaving exactly as before.
@MainActor
final class FloatingPanelDismissPolicyTests: XCTestCase {
    private final class StubWindow: NSWindow {}

    private func makeWindow() -> StubWindow {
        StubWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
    }

    func testClosesWhenThereIsNoCausingEvent() {
        XCTAssertTrue(
            FloatingPanelDismissPolicy.closesOnResignKey(
                eventType: nil,
                eventWindow: nil,
                isPinnedPreviewWindow: { _ in true }
            )
        )
    }

    func testClosesForNonMouseEvents() {
        XCTAssertTrue(
            FloatingPanelDismissPolicy.closesOnResignKey(
                eventType: .keyDown,
                eventWindow: makeWindow(),
                isPinnedPreviewWindow: { _ in true }
            ),
            "Only a click into the pinned preview is exempt"
        )
    }

    func testClosesWhenTheClickLandedOutsideAnyScopyWindow() {
        XCTAssertTrue(
            FloatingPanelDismissPolicy.closesOnResignKey(
                eventType: .leftMouseDown,
                eventWindow: nil,
                isPinnedPreviewWindow: { _ in true }
            ),
            "A click with no window of ours behind it means focus left Scopy"
        )
    }

    func testStaysOpenWhenTheClickLandedInThePinnedPreviewWindow() {
        let window = makeWindow()
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertFalse(
                FloatingPanelDismissPolicy.closesOnResignKey(
                    eventType: type,
                    eventWindow: window,
                    isPinnedPreviewWindow: { $0 === window }
                ),
                "Interacting with the pinned preview must not close the history panel (\(type.rawValue))"
            )
        }
    }

    func testClosesWhenTheClickLandedInADifferentScopyWindow() {
        XCTAssertTrue(
            FloatingPanelDismissPolicy.closesOnResignKey(
                eventType: .leftMouseDown,
                eventWindow: makeWindow(),
                isPinnedPreviewWindow: { _ in false }
            ),
            "Only the pinned preview is exempt; other windows keep the previous behaviour"
        )
    }
}
