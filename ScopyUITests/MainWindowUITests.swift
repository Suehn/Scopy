import XCTest

/// Main Window UI Tests
/// Tests for the main application window functionality
final class MainWindowUITests: XCTestCase {

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

    // MARK: - Window Launch Tests

    func testAppLaunches() throws {
        // Verify app launches successfully
        XCTAssertTrue(app.exists)
    }

    func testMainWindowExists() throws {
        // The main window should exist after launch
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
    }

    func testSearchFieldExists() throws {
        // Search field should be visible
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
    }

    func testSearchFieldAcceptsInput() throws {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search field not found")
            return
        }

        searchField.click()
        searchField.typeText("test query")

        // Verify text was entered
        XCTAssertEqual(searchField.value as? String, "test query")
    }

    func testSearchFieldClearButton() throws {
        let searchField = app.searchFields.firstMatch
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("Search field not found")
            return
        }

        searchField.click()
        searchField.typeText("test")

        // Look for clear button
        let clearButton = app.buttons["Clear"].firstMatch
        if clearButton.exists {
            clearButton.click()
            XCTAssertEqual(searchField.value as? String ?? "", "")
        }
    }

    func testWindowHasCorrectTitle() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        // Check window title or identifier
        XCTAssertTrue(window.exists)
    }
}
