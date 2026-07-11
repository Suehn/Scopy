import CoreGraphics
import XCTest

@MainActor
final class HistoryListRetainedInteractionUITests: XCTestCase {
    private enum ProbeID {
        static let attached = "UITest.HistoryListProbe.Attached"
        static let scrollStartCount = "UITest.HistoryListProbe.ScrollStartCount"
        static let scrollEndCount = "UITest.HistoryListProbe.ScrollEndCount"
        static let fileAppearCount = "UITest.HistoryListProbe.FileAppearCount"
        static let fileDisappearCount = "UITest.HistoryListProbe.FileDisappearCount"
        static let mockPersistedNote = "UITest.HistoryListProbe.MockPersistedNote"
        static let modelPersistedNote = "UITest.HistoryListProbe.ModelPersistedNote"
    }

    private static let imageTargetID = "53504359-1001-4000-8000-000000000001"
    private static let fileTargetID = "53504359-1001-4000-8000-000000000002"

    private var app: XCUIApplication!
    private var notificationNamespace = ""

    override func setUp() async throws {
        continueAfterFailure = false
        notificationNamespace = UUID().uuidString.lowercased()
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--history-list-retained-interaction"
        ]
        app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["SCOPY_UITEST_HISTORY_LIST_INTEGRATION"] = "1"
        app.launchEnvironment["SCOPY_UITEST_HISTORY_LIST_NAMESPACE"] = notificationNamespace
        app.launchEnvironment["SCOPY_MOCK_DATASET_ID"] = "history-list-retained-interaction-v1"
        app.launchEnvironment["SCOPY_MOCK_SHOW_THUMBNAILS"] = "0"
        // Keep hover previews out of the way while this suite exercises row controls and menus.
        app.launchEnvironment["SCOPY_MOCK_IMAGE_PREVIEW_DELAY"] = "10"
        app.launchEnvironment["SCOPY_MOCK_UPDATE_NOTE_DELAY_MS"] = "2000"
        app.launchEnvironment["SCOPY_PERF_PASSIVE_ROW"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Scopy test window did not appear")
        app.activate()
        waitForProbeValue("1", identifier: ProbeID.attached, timeout: 15)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        notificationNamespace = ""
    }

    func testStationaryHoverRestoresOptimizeAfterProductionScrollCooldown() throws {
        let imageRow = app.anyElement("History.Item.\(Self.imageTargetID)")
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10), "Image target row did not appear")

        imageRow.hover()
        // The row-level accessibility identifier can be inherited by the nested SwiftUI button;
        // its user-facing accessibility label remains stable in the real List hierarchy.
        let optimizeButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Optimize image")
        ).firstMatch
        XCTAssertTrue(
            optimizeButton.waitForExistence(timeout: 5),
            "A single hover did not reveal the image optimization action"
        )
        let cursorBefore = try cursorLocation()

        postCommand("scroll-start")
        waitForProbeCount(atLeast: 1, identifier: ProbeID.scrollStartCount)
        waitForDisappearance(
            optimizeButton,
            timeout: 5,
            message: "Production scroll start did not suppress the hovered row action"
        )

        postCommand("scroll-end")
        waitForProbeCount(atLeast: 1, identifier: ProbeID.scrollEndCount)
        XCTAssertTrue(
            optimizeButton.waitForExistence(timeout: 5),
            "Optimize did not restore after scroll cooldown without another hover"
        )

        let cursorAfter = try cursorLocation()
        XCTAssertEqual(cursorAfter.x, cursorBefore.x, accuracy: 0.5)
        XCTAssertEqual(cursorAfter.y, cursorBefore.y, accuracy: 0.5)
    }

    func testNoteDraftAndDelayedSaveSurviveRealListVirtualization() throws {
        let fileRow = app.anyElement("History.Item.\(Self.fileTargetID)")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 10), "File target row did not appear")
        let initialAppearCount = probeCount(identifier: ProbeID.fileAppearCount)
        XCTAssertGreaterThanOrEqual(initialAppearCount, 1)

        fileRow.rightClick()
        try clickContextMenuItem(
            identifier: "HistoryItem.ContextMenu.AddNote",
            title: "Add Note..."
        )

        let editor = app.popovers.firstMatch
        let textEditor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Note editor did not open")
        XCTAssertTrue(textEditor.waitForExistence(timeout: 5), "Note text editor did not appear")

        let note = "retained-note-\(UUID().uuidString.lowercased())"
        textEditor.click()
        textEditor.typeText(note)
        waitForElementValueContaining(note, element: textEditor)

        let firstDisappearTarget = probeCount(identifier: ProbeID.fileDisappearCount) + 1
        postCommand("jump-bottom")
        waitForProbeCount(
            atLeast: firstDisappearTarget,
            identifier: ProbeID.fileDisappearCount
        )
        XCTAssertGreaterThanOrEqual(
            probeCount(identifier: ProbeID.fileDisappearCount),
            firstDisappearTarget,
            "The real List did not virtualize the top file row"
        )

        postCommand("jump-top")
        waitForProbeCount(
            atLeast: initialAppearCount + 1,
            identifier: ProbeID.fileAppearCount
        )
        XCTAssertGreaterThanOrEqual(probeCount(identifier: ProbeID.fileAppearCount), 2)
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Retained note editor did not reappear")
        XCTAssertTrue(textEditor.waitForExistence(timeout: 5), "Retained note field did not reappear")
        waitForElementValueContaining(note, element: textEditor)

        let saveButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Save")
        ).firstMatch
        let cancelButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Cancel")
        ).firstMatch
        let progress = app.activityIndicators.firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button did not appear")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Cancel button did not appear")
        let secondDisappearTarget = probeCount(identifier: ProbeID.fileDisappearCount) + 1
        saveButton.click()
        XCTAssertTrue(progress.waitForExistence(timeout: 0.5), "Delayed save never entered saving state")
        XCTAssertFalse(cancelButton.isEnabled, "Cancel must not create ambiguous persistence while saving")
        XCTAssertFalse(textEditor.isEnabled, "The committed draft must remain immutable while saving")
        postCommand("jump-bottom")
        waitForProbeCount(
            atLeast: secondDisappearTarget,
            identifier: ProbeID.fileDisappearCount
        )
        XCTAssertGreaterThanOrEqual(
            probeCount(identifier: ProbeID.fileDisappearCount),
            secondDisappearTarget,
            "The real List did not recycle the file row during delayed note persistence"
        )
        waitForProbeValue(note, identifier: ProbeID.mockPersistedNote, timeout: 8)
        waitForProbeValue(note, identifier: ProbeID.modelPersistedNote, timeout: 8)

        postCommand("jump-top")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "Saved file row did not return")
        fileRow.rightClick()
        try clickContextMenuItem(
            identifier: "HistoryItem.ContextMenu.EditNote",
            title: "Edit Note..."
        )
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Edit Note did not reopen the editor")
        XCTAssertTrue(textEditor.waitForExistence(timeout: 5), "Saved note field did not reappear")
        waitForElementValueContaining(note, element: textEditor)
    }

    private func clickContextMenuItem(identifier: String, title: String) throws {
        let item = app.menuItems.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                identifier,
                title
            )
        ).firstMatch
        guard item.waitForExistence(timeout: 3) else {
            XCTFail("Context menu item not exposed: \(title)")
            return
        }
        item.click()
    }

    private func postCommand(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(
                "org.scopy.uitest.history-list.\(notificationNamespace).\(command)"
            ),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func waitForProbeValue(
        _ expected: String,
        identifier: String,
        timeout: TimeInterval = 5
    ) {
        let element = app.anyElement(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing probe \(identifier)")
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return self.elementValue(element) == expected
        }
        waitForPredicate(
            predicate,
            on: element,
            timeout: timeout,
            message: "Expected \(identifier) to equal \(expected)"
        )
    }

    private func waitForProbeCount(
        atLeast expected: Int,
        identifier: String,
        timeout: TimeInterval = 5
    ) {
        let element = app.anyElement(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing probe \(identifier)")
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return Int(self.elementValue(element)) ?? -1 >= expected
        }
        waitForPredicate(
            predicate,
            on: element,
            timeout: timeout,
            message: "Expected \(identifier) to reach at least \(expected)"
        )
    }

    private func probeCount(identifier: String) -> Int {
        let element = app.anyElement(identifier)
        XCTAssertTrue(element.exists, "Missing probe \(identifier)")
        let value = Int(elementValue(element))
        XCTAssertNotNil(value, "Probe \(identifier) did not expose an integer value")
        return value ?? 0
    }

    private func waitForElementValueContaining(
        _ expected: String,
        element: XCUIElement,
        timeout: TimeInterval = 5
    ) {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return self.elementValue(element).contains(expected)
        }
        waitForPredicate(
            predicate,
            on: element,
            timeout: timeout,
            message: "Expected \(element.identifier) to retain exact note text"
        )
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String
    ) {
        waitForPredicate(
            NSPredicate(format: "exists == 0"),
            on: element,
            timeout: timeout,
            message: message
        )
    }

    private func elementValue(_ element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        return element.label
    }

    private func cursorLocation() throws -> CGPoint {
        guard let location = CGEvent(source: nil)?.location else {
            XCTFail("Unable to read the stationary cursor location")
            throw CursorReadError.unavailable
        }
        return location
    }

    private enum CursorReadError: Error {
        case unavailable
    }
}
