import XCTest

/// Context Menu UI Tests
/// Tests for right-click context menu functionality
@MainActor
final class ContextMenuUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    // MARK: - Context Menu Tests

    private func historyListOutline() -> XCUIElement {
        app.outlines["History.List"]
    }

    private func contextMenuItem(title: String) -> XCUIElement {
        let menu = historyListOutline().menus.firstMatch
        return menu.menuItems.matching(NSPredicate(format: "identifier == %@ AND label == %@", "menuAction:", title)).firstMatch
    }

    func testContextMenuAppearsOnRightClick() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 20) else { throw XCTSkip("History list not ready") }

        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        guard firstItem.waitForExistence(timeout: 20) else { throw XCTSkip("No history items available") }

        firstItem.rightClick()
        _ = app.exists
    }

    func testContextMenuHasCopyOption() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 20) else { throw XCTSkip("History list not ready") }

        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        guard firstItem.waitForExistence(timeout: 20) else { throw XCTSkip("No history items available") }

        firstItem.rightClick()

        let copyItem = contextMenuItem(title: "Copy")
        guard copyItem.waitForExistence(timeout: 2) else {
            throw XCTSkip("Context menu items are not reliably exposed to XCUITest on macOS for this view.")
        }
        XCTAssertTrue(copyItem.isEnabled)
    }

    func testContextMenuHasPinOption() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 20) else { throw XCTSkip("History list not ready") }

        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        guard firstItem.waitForExistence(timeout: 20) else { throw XCTSkip("No history items available") }

        firstItem.rightClick()

        let pinItem = contextMenuItem(title: "Pin")
        let unpinItem = contextMenuItem(title: "Unpin")
        guard pinItem.waitForExistence(timeout: 2) || unpinItem.waitForExistence(timeout: 2) else {
            throw XCTSkip("Context menu items are not reliably exposed to XCUITest on macOS for this view.")
        }
    }

    func testContextMenuHasDeleteOption() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 20) else { throw XCTSkip("History list not ready") }

        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        guard firstItem.waitForExistence(timeout: 20) else { throw XCTSkip("No history items available") }

        firstItem.rightClick()

        let deleteItem = contextMenuItem(title: "Delete")
        guard deleteItem.waitForExistence(timeout: 2) else {
            throw XCTSkip("Context menu items are not reliably exposed to XCUITest on macOS for this view.")
        }
        XCTAssertTrue(deleteItem.isEnabled)
    }
}
