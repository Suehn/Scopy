import XCTest

/// Keyboard Navigation UI Tests
/// Tests for keyboard shortcuts and navigation
@MainActor
final class KeyboardNavigationUITests: XCTestCase {

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

    // MARK: - Arrow Key Navigation

    func testSearchFocusAllowsHoverSelectionCandidate() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 10) else {
            XCTFail("History list not found")
            return
        }

        let searchField = app.anyElement("History.SearchField")
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Search field not found")
            return
        }
        searchField.click()

        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        guard firstItem.waitForExistence(timeout: 10) else {
            XCTFail("No history items found")
            return
        }

        firstItem.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let selectedItem = app.anyElements(
            matching: NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "History.Item.",
                "selected"
            )
        ).firstMatch
        XCTAssertTrue(selectedItem.waitForExistence(timeout: 5), "Hovering the list should still select a row while the search field is focused.")
    }

    func testEscapeKeyClearsSearch() throws {
        let searchField = app.anyElement("History.SearchField")
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Search field not found")
            return
        }

        // Enter search text
        searchField.click()
        searchField.typeText("test")

        // Press escape
        app.windows.firstMatch.typeKey(.escape, modifierFlags: [])

        // Search should be cleared (or panel closed). We assert the query is no longer "test".
        waitForPredicate(
            NSPredicate(format: "NOT (value CONTAINS[c] %@)", "test"),
            on: searchField,
            timeout: 2,
            message: "Escape did not clear the search field"
        )
    }

}
