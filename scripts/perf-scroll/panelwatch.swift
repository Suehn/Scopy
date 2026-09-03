import AppKit
import CoreGraphics
// Precise hotkey -> panel-visible latency.
// usage: panelwatch <pid> --hotkey <vk> [--timeout 5]
// Resolves the panel's window number once (from the full window list, which includes off-screen windows),
// then polls only that window's on-screen flag, which is far cheaper than enumerating every window and keeps
// the sampling interval near the microsecond range instead of ~17 ms.
let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else { print("usage: panelwatch <pid> --hotkey <vk>"); exit(64) }
let vk = args.firstIndex(of: "--hotkey").map { CGKeyCode(UInt16(args[$0 + 1])!) } ?? 8
let timeout = args.firstIndex(of: "--timeout").map { Double(args[$0 + 1]) ?? 5 } ?? 5

func allWindows(_ opts: CGWindowListOption) -> [[String: Any]] {
    (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
}
// The panel is the pid's largest window; look it up in the full list so it is found while ordered out too.
var windowNumber: CGWindowID? = nil
var best: CGFloat = 0
for w in allWindows([.optionAll, .excludeDesktopElements]) where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let wid = w[kCGWindowNumber as String] as? CGWindowID,
          let width = b["Width"], let height = b["Height"], width > 200, height > 200 else { continue }
    if width * height > best { best = width * height; windowNumber = wid }
}
guard let wid = windowNumber else { print("no panel window"); exit(1) }
func isOnScreen() -> Bool {
    for w in allWindows([.optionOnScreenOnly, .excludeDesktopElements]) where (w[kCGWindowNumber as String] as? CGWindowID) == wid { return true }
    return false
}
let was = isOnScreen()
// Calibrate the polling loop itself so the reported latency can be read against its own resolution.
var calib: [Double] = []
for _ in 0..<200 { let t = CFAbsoluteTimeGetCurrent(); _ = isOnScreen(); calib.append((CFAbsoluteTimeGetCurrent() - t) * 1000) }
let calibAvg = calib.reduce(0, +) / Double(calib.count)
let t0 = CFAbsoluteTimeGetCurrent()
let src = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    let ev = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)!
    ev.flags = [.maskShift, .maskCommand]
    ev.post(tap: .cghidEventTap)
}
var changed = Double.nan
var polls = 0
while CFAbsoluteTimeGetCurrent() - t0 < timeout {
    polls += 1
    if isOnScreen() != was { changed = (CFAbsoluteTimeGetCurrent() - t0) * 1000; break }
}
print(String(format: "%@ %@_ms=%.1f polls=%d poll_cost_ms=%.2f",
             was ? "close" : "open", was ? "hidden" : "visible", changed, polls, calibAvg))
