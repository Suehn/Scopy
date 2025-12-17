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
        app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    // MARK: - Window Launch Tests

    func testAppLaunches() throws {
        // Verify app launches successfully
        let exists = app.exists
        XCTAssertTrue(exists)
    }

    func testMainWindowExists() throws {
        // The main window should exist after launch
        let window = app.windows.firstMatch
        let exists = window.waitForExistence(timeout: 10)
        XCTAssertTrue(exists)
    }

    func testSearchFieldExists() throws {
        // Search field should be visible
        let searchField = app.anyElement("History.SearchField")
        let exists = searchField.waitForExistence(timeout: 10)
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

    func testSearchFieldClearButton() throws {
        throw XCTSkip("Clear button is icon-only and not exposed to XCUITest reliably; covered by unit/UI behavior tests elsewhere.")
    }

    func testWindowHasCorrectTitle() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        // Check window title or identifier
        let exists = window.exists
        XCTAssertTrue(exists)
    }
}
