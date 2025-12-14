import XCTest

/// Settings Window UI Tests
/// Tests for the settings/preferences window
@MainActor
final class SettingsUITests: XCTestCase {

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

    // MARK: - Settings Window Tests

    func testSettingsWindowOpensWithKeyboard() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Main window not found")
            return
        }

        // Open settings with Cmd+,
        window.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Settings.SaveButton"].waitForExistence(timeout: 3))
    }

    func testSettingsHasMaxItemsControl() throws {
        // Open settings
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        window.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Settings.SaveButton"].waitForExistence(timeout: 3))

        // Open Storage page and verify picker exists
        app.staticTexts["存储"].click()
        XCTAssertTrue(app.popUpButtons["Settings.MaxItemsPicker"].waitForExistence(timeout: 2))
    }

    func testSettingsSaveButton() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        window.typeKey(",", modifierFlags: .command)
        let saveButton = app.buttons["Settings.SaveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3))

        XCTAssertTrue(saveButton.isEnabled)
    }

    func testSettingsCancelButton() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        window.typeKey(",", modifierFlags: .command)
        let cancelButton = app.buttons["Settings.CancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))

        cancelButton.click()
    }
}
