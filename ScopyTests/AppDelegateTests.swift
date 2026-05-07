import CoreGraphics
import XCTest
@testable import Scopy

#if !SCOPY_TSAN_TESTS
final class AppDelegateTests: XCTestCase {
    func testCodexPasteShortcutUsesControlV() {
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.virtualKey, 9)
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.flags, .maskControl)
    }
}
#endif
