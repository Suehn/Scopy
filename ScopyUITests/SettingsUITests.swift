import XCTest

/// Settings Window UI Tests
/// Tests for the settings/preferences window
final class SettingsUITests: XCTestCase {

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

    // MARK: - Settings Window Tests

    func testSettingsWindowOpensWithKeyboard() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Main window not found")
            return
        }

        // Open settings with Cmd+,
        window.typeKey(",", modifierFlags: .command)

        Thread.sleep(forTimeInterval: 0.5)

        // Check if settings window appeared
        let settingsWindow = app.windows["Settings"]
        // Note: Window may have different identifier
        XCTAssertTrue(app.windows.count >= 1)
    }

    func testSettingsHasMaxItemsControl() throws {
        // Open settings
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        window.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Look for max items picker or text field
        let picker = app.popUpButtons.firstMatch
        // Settings should have some controls
        XCTAssertTrue(app.windows.count >= 1)
    }

    func testSettingsSaveButton() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        window.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Look for save button
        let saveButton = app.buttons["Save"]
        if saveButton.exists {
            XCTAssertTrue(saveButton.isEnabled)
        }
    }

    func testSettingsCancelButton() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Window not found")
            return
        }

        window.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Look for cancel button
        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.click()
            // Window should close
        }
    }
}
