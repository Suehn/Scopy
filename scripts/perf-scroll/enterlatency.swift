import AppKit
import CoreGraphics
// Measures the outbound copy round trip: return key -> content on the pasteboard -> panel hidden.
// usage: enterlatency <pid> <pasteboardName> [--timeout 6] [--down N]
// The profiled instance writes copies to its private named pasteboard (SCOPY_SERVICE_MONITOR_PASTEBOARD),
// so the change count of that pasteboard can be polled from outside without touching the system clipboard.
let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else { print("usage: enterlatency <pid> <pasteboardName>"); exit(64) }
let pb = NSPasteboard(name: NSPasteboard.Name(args[2]))
let timeout = args.firstIndex(of: "--timeout").map { Double(args[$0 + 1]) ?? 6 } ?? 6
let downCount = args.firstIndex(of: "--down").map { Int(args[$0 + 1]) ?? 0 } ?? 0

func panelOnScreen() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 200, (b["Width"] ?? 0) > 200 else { continue }
        return true
    }
    return false
}
func key(_ vk: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)!.post(tap: .cghidEventTap) }
}
// Moves the pointer and presses the button first, then returns so the caller can start the clock
// immediately before the mouse-up that actually fires the row's button.
func clickDown(_ x: Double, _ y: Double) {
    let src = CGEventSource(stateID: .hidSystemState)
    let p = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(40_000)
}
func clickUp(_ x: Double, _ y: Double) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!.post(tap: .cghidEventTap)
}
// --click <x> <y>: activate a row by clicking it, which reaches a non-activating panel even when the
// application is not frontmost; without it the tool presses return.
let clickAt: (Double, Double)? = args.firstIndex(of: "--click").map { (Double(args[$0 + 1])!, Double(args[$0 + 2])!) }
guard panelOnScreen() else { print("panel not open"); exit(1) }
for _ in 0..<downCount { key(125); usleep(120_000) }   // arrow down
usleep(300_000)
if let c = clickAt { clickDown(c.0, c.1) }
let before = pb.changeCount
let t0 = CFAbsoluteTimeGetCurrent()
if let c = clickAt { clickUp(c.0, c.1) } else { key(36) }
var pasteMs = Double.nan, hiddenMs = Double.nan
let deadline = t0 + timeout
while CFAbsoluteTimeGetCurrent() < deadline {
    if pasteMs.isNaN, pb.changeCount != before { pasteMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
    if hiddenMs.isNaN, !panelOnScreen() { hiddenMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
    if !pasteMs.isNaN && !hiddenMs.isNaN { break }
    usleep(1000)
}
let bytes = pb.data(forType: .string)?.count ?? -1
print(String(format: "activate pasteboard_ms=%.1f hidden_ms=%.1f bytes=%d", pasteMs, hiddenMs, bytes))
