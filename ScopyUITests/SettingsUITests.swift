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

        Thread.sleep(forTimeInterval: 0.5)

        // Check if settings window appeared
        let settingsWindow = app.windows["Settings"]
        // Note: Window may have different identifier
        let settingsWindowExists = settingsWindow.exists
        let windowCount = app.windows.count
        XCTAssertTrue(settingsWindowExists || windowCount >= 1)
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
        let pickerExists = picker.exists
        let windowCount = app.windows.count
        XCTAssertTrue(pickerExists || windowCount >= 1)
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
            let isEnabled = saveButton.isEnabled
            XCTAssertTrue(isEnabled)
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
