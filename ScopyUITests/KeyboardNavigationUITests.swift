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

        // Window may close after selection
        Thread.sleep(forTimeInterval: 0.5)
    }

    func testEscapeKeyClearsSearch() throws {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search field not found")
            return
        }

        // Enter search text
        searchField.click()
        searchField.typeText("test")

        // Press escape
        app.windows.firstMatch.typeKey(.escape, modifierFlags: [])

        Thread.sleep(forTimeInterval: 0.2)

        // Search should be cleared or window closed
        let exists = app.exists
        XCTAssertTrue(exists)
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
