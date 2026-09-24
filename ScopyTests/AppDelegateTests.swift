import AppKit
import CoreGraphics
import XCTest
@testable import Scopy

#if !SCOPY_TSAN_TESTS
final class AppDelegateTests: XCTestCase {
    func testCodexPasteShortcutUsesControlV() {
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.virtualKey, 9)
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.flags, .maskControl)
    }

    @MainActor
    func testOptionDeleteNeverDeletesWhileTextIsBeingEdited() {
        let history = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let searchField = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        history.contentView?.addSubview(searchField)

        XCTAssertTrue(AppDelegate.OptionDeleteShortcut.deletesItem(eventWindow: history, historyWindow: history))
        XCTAssertFalse(AppDelegate.OptionDeleteShortcut.deletesItem(eventWindow: other, historyWindow: history))

        XCTAssertTrue(history.makeFirstResponder(searchField))
        XCTAssertFalse(AppDelegate.OptionDeleteShortcut.deletesItem(eventWindow: history, historyWindow: history))
    }
}
#endif
