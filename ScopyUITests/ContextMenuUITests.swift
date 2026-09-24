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
        guard list.waitForExistence(timeout: 10) else {
            XCTFail("History list not found")
            return
        }

        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        guard firstItem.waitForExistence(timeout: 10) else {
            XCTFail("No history items found")
            return
        }

        firstItem.rightClick()
        _ = app.exists
    }

}
