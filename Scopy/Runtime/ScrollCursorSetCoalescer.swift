import AppKit
import ObjectiveC

/// Skips redundant `NSCursor.set` bursts.
///
/// AppKit re-evaluates the cursor on every display cycle in which tracking areas moved, which is every frame of a
/// scroll, and SwiftUI's hosting view answers each `cursorUpdate` by setting the arrow cursor again. With an
/// Accessibility pointer customization active (enlarged or recolored pointer) every `set` regenerates the cursor image
/// through AccessibilityFoundation: measured at about 70 calls per second, 3 ms each, all setting the cursor that was
/// already current, or 21% of wall time while scrolling the history list. Setting the current cursor again changes
/// nothing on screen, so a `set` of the cursor that is already current and was set less than `burstWindow` ago is
/// dropped; a different cursor, or the first set after a pause, runs unchanged. Scroll input itself is not observable
/// here (responsive scrolling consumes wheel events off the main event loop), which is why the burst cadence is used.
enum ScrollCursorSetCoalescer {
    nonisolated(unsafe) private static var lastSetNanos: UInt64 = 0
    nonisolated(unsafe) private static var lastSetCursor: ObjectIdentifier?
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var skipped = 0
    nonisolated(unsafe) private static var performed = 0
    private static let burstWindowNanos: UInt64 = 100_000_000
    private static let traceEnabled = ProcessInfo.processInfo.environment["SCOPY_PERF_TRACE_CURSOR_SET"] == "1"

    @MainActor
    static func install() {
        guard !installed,
              let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)),
              let replacement = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.scopyCoalescedSet))
        else { return }
        installed = true
        method_exchangeImplementations(original, replacement)
    }

    /// Returns whether the call can be dropped, and records the call either way.
    fileprivate static func shouldSkip(_ cursor: NSCursor) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let identifier = ObjectIdentifier(cursor)
        let redundant = NSCursor.current === cursor
            && lastSetCursor == identifier
            && now &- lastSetNanos < burstWindowNanos
        lastSetNanos = now
        lastSetCursor = identifier
        if traceEnabled {
            if redundant { skipped += 1 } else { performed += 1 }
            if (skipped + performed) % 120 == 0 {
                NSLog("[cursor-set] performed=%d skipped=%d", performed, skipped)
            }
        }
        return redundant
    }
}

extension NSCursor {
    @objc fileprivate func scopyCoalescedSet() {
        if ScrollCursorSetCoalescer.shouldSkip(self) { return }
        scopyCoalescedSet() // the original implementation after the exchange
    }
}
