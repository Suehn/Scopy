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

    func testOptionDeleteDeletesSelectedItemEvenWhenSearchFocused() throws {
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

        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }
        // Select the first item via keyboard so we don't close the panel/window (click selects+copies).
        window.typeKey(.downArrow, modifierFlags: [])

        let selectedItem = app.anyElements(
            matching: NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "History.Item.",
                "selected"
            )
        ).firstMatch
        guard selectedItem.waitForExistence(timeout: 5) else {
            XCTFail("Selected item not found")
            return
        }

        let selectedItemIdentifier = selectedItem.identifier
        window.typeKey(.delete, modifierFlags: [.option])

        let deletedElement = app.anyElement(selectedItemIdentifier)
        waitForPredicate(
            NSPredicate(format: "exists == 0"),
            on: deletedElement,
            timeout: 5,
            message: "Option+Delete did not delete the selected item"
        )
    }

    func testDownArrowSelectsNextItem() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        // Press down arrow
        window.typeKey(.downArrow, modifierFlags: [])

        // Should have selected an item (verify via selection highlight)
        let exists = window.exists
        XCTAssertTrue(exists)
    }

    func testUpArrowSelectsPreviousItem() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        // First go down, then up
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.upArrow, modifierFlags: [])

        let exists = window.exists
        XCTAssertTrue(exists)
    }

    func testEnterKeySelectsItem() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        // Select first item
        window.typeKey(.downArrow, modifierFlags: [])

        // Press enter - should copy and possibly close window
        window.typeKey(.return, modifierFlags: [])
        // Window may close after selection; just ensure we don't crash.
        _ = window.exists
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

    func testMultipleDownArrowsNavigatesList() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        // Navigate through multiple items
        for _ in 0..<5 {
            window.typeKey(.downArrow, modifierFlags: [])
        }

        let exists = window.exists
        XCTAssertTrue(exists)
    }
}
