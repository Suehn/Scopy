import XCTest

/// Main Window UI Tests
/// Tests for the main application window functionality
@MainActor
final class MainWindowUITests: XCTestCase {

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

    // MARK: - Window Launch Tests

    func testMainWindowExists() throws {
        // The main window should exist after launch
        let window = app.windows.firstMatch
        let exists = window.waitForExistence(timeout: 10)
        XCTAssertTrue(exists)
    }

    func testSearchFieldAcceptsInput() throws {
        let searchField = app.anyElement("History.SearchField")
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Search field not found")
            return
        }

        searchField.click()
        searchField.typeText("test query")

        // Verify text was entered
        let value = searchField.value as? String
        XCTAssertEqual(value, "test query")
    }

}
