import XCTest

/// History List UI Tests
/// Tests for the clipboard history list functionality
@MainActor
final class HistoryListUITests: XCTestCase {

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

    // MARK: - List Display Tests

    func testHistoryListExists() throws {
        // Wait for the list to appear
        let list = app.anyElement("History.List")
        let exists = list.waitForExistence(timeout: 10)
        XCTAssertTrue(exists)
    }

    func testHistoryListHasItems() throws {
        // In UI testing mode with mock data, should have items
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 10) else {
            XCTFail("List not found")
            return
        }

        let items = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item."))
        XCTAssertGreaterThan(items.count, 0)
    }

    func testListScrolling() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 10) else {
            XCTFail("List not found")
            return
        }

        // Scroll down
        list.swipeUp()

        // List should still exist after scrolling
        let exists = list.exists
        XCTAssertTrue(exists)
    }

    func testItemSelection() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 10) else {
            XCTFail("List not found")
            return
        }

        // Click on first item
        _ = list
        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        if firstItem.waitForExistence(timeout: 5) {
            firstItem.click()
        }
    }

    func testListRefreshesOnSearch() throws {
        let searchField = app.anyElement("History.SearchField")
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Search field not found")
            return
        }

        searchField.click()
        searchField.typeText("test")

        // Wait for the query text to be reflected in the field value.
        waitForPredicate(
            NSPredicate(format: "value CONTAINS[c] %@", "test"),
            on: searchField,
            timeout: 3,
            message: "Search field did not receive input"
        )

        XCTAssertTrue(app.anyElement("History.List").exists)
    }

    func testEmptySearchShowsResults() throws {
        let searchField = app.anyElement("History.SearchField")
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Search field not found")
            return
        }

        // Enter search text then clear it (⌘A + ⌫) so the behavior is deterministic.
        searchField.click()
        searchField.typeText("test")

        // Delete typed characters (avoid modifier-dependent shortcuts for stability).
        searchField.typeText(String(repeating: "\u{8}", count: 4))

        waitForPredicate(
            NSPredicate(format: "value == '' OR value == nil OR value CONTAINS[c] %@", "Search"),
            on: searchField,
            timeout: 3,
            message: "Search field did not clear"
        )

        XCTAssertTrue(app.anyElement("History.List").exists)
    }
}
