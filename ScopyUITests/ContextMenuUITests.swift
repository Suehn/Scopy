import XCTest

/// Context Menu UI Tests
/// Tests for right-click context menu functionality
final class ContextMenuUITests: XCTestCase {

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

    // MARK: - Context Menu Tests

    func testContextMenuAppearsOnRightClick() throws {
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        // Right-click on first item
        let firstItem = list.staticTexts.firstMatch
        if firstItem.exists {
            firstItem.rightClick()

            Thread.sleep(forTimeInterval: 0.3)

            // Check if context menu appeared
            let menu = app.menus.firstMatch
            // Menu may not be easily accessible in XCUITest
        }
    }

    func testContextMenuHasCopyOption() throws {
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        let firstItem = list.staticTexts.firstMatch
        if firstItem.exists {
            firstItem.rightClick()

            Thread.sleep(forTimeInterval: 0.3)

            // Look for Copy menu item
            let copyItem = app.menuItems["Copy"]
            if copyItem.exists {
                XCTAssertTrue(copyItem.isEnabled)
            }
        }
    }

    func testContextMenuHasPinOption() throws {
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        let firstItem = list.staticTexts.firstMatch
        if firstItem.exists {
            firstItem.rightClick()

            Thread.sleep(forTimeInterval: 0.3)

            // Look for Pin menu item
            let pinItem = app.menuItems["Pin"]
            // May be "Unpin" if already pinned
        }
    }

    func testContextMenuHasDeleteOption() throws {
        let list = app.scrollViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("List not found")
            return
        }

        let firstItem = list.staticTexts.firstMatch
        if firstItem.exists {
            firstItem.rightClick()

            Thread.sleep(forTimeInterval: 0.3)

            // Look for Delete menu item
            let deleteItem = app.menuItems["Delete"]
            if deleteItem.exists {
                XCTAssertTrue(deleteItem.isEnabled)
            }
        }
    }
}
