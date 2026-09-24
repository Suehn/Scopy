import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Scopy

#if !SCOPY_TSAN_TESTS
final class AppDelegateTests: XCTestCase {
    func testCodexPasteShortcutUsesControlV() {
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.virtualKey, 9)
        XCTAssertEqual(AppDelegate.CodexPasteShortcut.flags, .maskControl)
    }

    func testQuickSlotShortcutMapsANSIDigitKeyCodesInRowOrder() {
        // kVK_ANSI_1…9 are not contiguous: 6 sits at 22 and 5 at 23, 9 at 25 and 7 at 26.
        let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        XCTAssertEqual(keyCodes.map { AppDelegate.QuickSlotShortcut.slot(forKeyCode: $0) }, Array(1...9))
        XCTAssertNil(AppDelegate.QuickSlotShortcut.slot(forKeyCode: UInt16(kVK_ANSI_0)))
        XCTAssertNil(AppDelegate.QuickSlotShortcut.slot(forKeyCode: UInt16(kVK_ANSI_Z)))
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
