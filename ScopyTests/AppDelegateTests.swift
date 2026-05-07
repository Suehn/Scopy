import CoreGraphics
import XCTest
@testable import Scopy

final class AppDelegateTests: XCTestCase {
    func testCodexPasteShortcutUsesControlV() {
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.virtualKey, 9)
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.flags, .maskControl)
    }
}
