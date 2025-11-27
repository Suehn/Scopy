import XCTest

/// History List UI Tests
/// Tests for the clipboard history list functionality
final class HistoryListUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - List Display Tests

    func testHistoryListExists() throws {
        // Wait for the list to appear
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
    }

    func testHistoryListHasItems() throws {
        // In UI testing mode with mock data, should have items
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        // Check for text elements in the list
        let staticTexts = list.staticTexts
        XCTAssertGreaterThan(staticTexts.count, 0)
    }

    func testListScrolling() throws {
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        // Scroll down
        list.swipeUp()

        // List should still exist after scrolling
        XCTAssertTrue(list.exists)
    }

    func testItemSelection() throws {
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        // Click on first item
        let firstItem = list.staticTexts.firstMatch
        if firstItem.exists {
            firstItem.click()
            // Item should remain visible or window may close
        }
    }

    func testListRefreshesOnSearch() throws {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search field not found")
            return
        }

        searchField.click()
        searchField.typeText("test")

        // Wait for search results
        Thread.sleep(forTimeInterval: 0.3) // Wait for debounce

        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.exists)
    }

    func testEmptySearchShowsResults() throws {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search field not found")
            return
        }

        // Clear search
        searchField.click()
        searchField.typeText("\u{8}") // Backspace

        Thread.sleep(forTimeInterval: 0.3)

        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.exists)
    }
}
