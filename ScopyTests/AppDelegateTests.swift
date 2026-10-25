import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
import ScopyKit
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

    @MainActor
    func testHotKeyRecordingRejectsOldSessionsAndCancelRestoresLatestCommittedShortcut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-hotkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(suiteName: directory.appendingPathComponent("settings").path)
        var registeredKeys: [UInt32] = []
        let delegate = AppDelegate.forTesting(settingsStore: store) { keyCode, _ in
            registeredKeys.append(keyCode)
            return true
        }

        let initial = await delegate.applyHotKey(keyCode: 10, modifiers: 20)
        XCTAssertTrue(initial)
        let oldSession = delegate.beginHotKeyRecordingForTesting()
        let currentSession = delegate.beginHotKeyRecordingForTesting()
        let staleApplication = await oldSession.finish(.shortcut(keyCode: 30, modifiers: 40))
        XCTAssertFalse(staleApplication)
        let staleCancellation = await oldSession.finish(.cancel)
        XCTAssertFalse(staleCancellation)

        await store.updateHotkey(keyCode: 50, modifiers: 60)
        let settingsReapplication = await delegate.applyHotKey(keyCode: 50, modifiers: 60)
        XCTAssertFalse(settingsReapplication, "Recording keeps the global shortcut suspended")
        XCTAssertEqual(registeredKeys, [10])

        let cancellation = await currentSession.finish(.cancel)
        XCTAssertTrue(cancellation)
        XCTAssertEqual(registeredKeys, [10, 50], "Cancel restores committed state, not the recording's old draft")
        let persisted = await store.load()
        XCTAssertEqual(persisted.hotkeyKeyCode, 50)
        XCTAssertEqual(persisted.hotkeyModifiers, 60)
    }

    @MainActor
    func testHotKeyFailureReturnsAfterRestoringAndPersistingThePreviousShortcut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-hotkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(suiteName: directory.appendingPathComponent("settings").path)
        var registeredKeys: [UInt32] = []
        let delegate = AppDelegate.forTesting(settingsStore: store) { keyCode, _ in
            registeredKeys.append(keyCode)
            return keyCode != 99
        }

        let initial = await delegate.applyHotKey(keyCode: 10, modifiers: 20)
        XCTAssertTrue(initial)
        let session = delegate.beginHotKeyRecordingForTesting()
        let applied = await session.finish(.shortcut(keyCode: 99, modifiers: 40))

        XCTAssertFalse(applied)
        XCTAssertEqual(registeredKeys, [10, 99, 10])
        let persisted = await store.load()
        XCTAssertEqual(persisted.hotkeyKeyCode, 10)
        XCTAssertEqual(persisted.hotkeyModifiers, 20)
    }
}
#endif
