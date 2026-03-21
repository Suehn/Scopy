import XCTest
import Foundation

@MainActor
final class HistoryItemViewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testPrimaryActionIncrementsSelectionCountWithoutOptimizing() throws {
        launchHarness(scenario: "plain-text")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        tapMainAction()

        waitForValue("select=1", identifier: "UITest.HistoryItemHarness.SelectCount")
        waitForValue("optimize=0", identifier: "UITest.HistoryItemHarness.OptimizeCount")
    }

    func testOptimizeButtonDoesNotTriggerPrimaryAction() throws {
        launchHarness(scenario: "image")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        tapOptimizeAction()

        waitForValue("optimize=1", identifier: "UITest.HistoryItemHarness.OptimizeCount")
        waitForValue("select=0", identifier: "UITest.HistoryItemHarness.SelectCount")
    }

    func testMarkdownScenarioShowsExportPNGInContextMenu() throws {
        let dumpPath = "/tmp/scopy_uitest_history_item_export.png"
        let errorPath = "/tmp/scopy_uitest_history_item_export_error.txt"
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        launchHarness(scenario: "markdown-text", dumpPath: dumpPath, errorPath: errorPath)

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        triggerExportPNGFromContextMenu()

        waitForFile(atPath: dumpPath, timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: errorPath))
        waitForValue("pin=0", identifier: "UITest.HistoryItemHarness.PinCount")
    }

    func testPlainTextScenarioHidesExportPNGInContextMenu() throws {
        let dumpPath = "/tmp/scopy_uitest_history_item_plain_export.png"
        let errorPath = "/tmp/scopy_uitest_history_item_plain_export_error.txt"
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        launchHarness(scenario: "plain-text", dumpPath: dumpPath, errorPath: errorPath)

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        assertExportPNGHiddenInContextMenu()

        assertFileDoesNotExist(atPath: dumpPath, timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: errorPath))
        waitForValue("pin=1", identifier: "UITest.HistoryItemHarness.PinCount")
    }

    private func launchHarness(scenario: String, dumpPath: String? = nil, errorPath: String? = nil) {
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_SCENARIO"] = scenario
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_KEYBOARD_SELECTED"] = "1"
        if let dumpPath {
            app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        }
        if let errorPath {
            app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        }
        app.launch()
    }

    private func historyItemButton(identifier: String) -> XCUIElement {
        app.buttons[identifier]
    }

    private func contextMenuItem(identifier: String, title: String) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, title)).firstMatch
    }

    private func tapMainAction() {
        let action = historyItemButton(identifier: "HistoryItem.MainAction")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let selectCountIdentifier = "UITest.HistoryItemHarness.SelectCount"
        let clickTargets: [CGVector] = [
            CGVector(dx: 0.10, dy: 0.50),
            CGVector(dx: 0.18, dy: 0.50),
            CGVector(dx: 0.26, dy: 0.50),
            CGVector(dx: 0.35, dy: 0.50)
        ]

        for offset in clickTargets {
            action.coordinate(withNormalizedOffset: offset).click()
            if displayedText(identifier: selectCountIdentifier) == "select=1" {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func tapOptimizeAction() {
        let optimize = historyItemButton(identifier: "HistoryItem.OptimizeButton")
        XCTAssertTrue(optimize.waitForExistence(timeout: 5))
        optimize.click()
    }

    private func openContextMenu() {
        let row = historyItemButton(identifier: "HistoryItem.MainAction")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
    }

    private func triggerExportPNGFromContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let exportItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.ExportPNG", title: "Export PNG")
        XCTAssertTrue(exportItem.waitForExistence(timeout: 2))
        exportItem.click()
    }

    private func assertExportPNGHiddenInContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let pinItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Pin", title: "Pin")
        XCTAssertTrue(pinItem.waitForExistence(timeout: 2))

        let exportItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.ExportPNG", title: "Export PNG")
        XCTAssertFalse(exportItem.waitForExistence(timeout: 1))

        pinItem.click()
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected file at \(path) within \(timeout) seconds")
    }

    private func assertFileDoesNotExist(atPath path: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                XCTFail("Did not expect file at \(path)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func waitForValue(_ expected: String, identifier: String, timeout: TimeInterval = 5) {
        let element = app.anyElement(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected \(identifier) to become \(expected)")
    }

    private func displayedText(identifier: String) -> String? {
        let element = app.anyElement(identifier)
        guard element.waitForExistence(timeout: 1) else { return nil }
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label.isEmpty ? nil : element.label
    }
}
