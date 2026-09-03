import AppKit
import ApplicationServices
import CoreGraphics
// Measures how long the panel takes to become visible and responsive after the global hotkey.
// usage: panelready <pid> --hotkey <virtualKey> [--timeout 8] [--count-rows]
// Accessibility queries are answered on the app's main thread, so the latency of a *cheap*, constant-cost
// query is a direct read of main-thread availability. After posting the hotkey the tool polls such a query
// every 5 ms and reports: when the window is on screen, the worst query latency seen, and when the main
// thread went quiet (three consecutive answers under 10 ms).
let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else { print("usage: panelready <pid> --hotkey <vk>"); exit(64) }
let timeout = args.firstIndex(of: "--timeout").map { Double(args[$0 + 1]) ?? 8 } ?? 8
let countRows = args.contains("--count-rows")
let vk = args.firstIndex(of: "--hotkey").map { CGKeyCode(UInt16(args[$0 + 1])!) }

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, Float(timeout))

func panelOnScreen() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 200, (b["Width"] ?? 0) > 200 else { continue }
        return true
    }
    return false
}
// Constant-cost query: the app's window list plus that window's role. Cost does not grow with the row count.
func cheapProbe() -> Double {
    let t = CFAbsoluteTimeGetCurrent()
    if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let win = windows.first {
        _ = attr(win, kAXRoleAttribute)
    }
    return (CFAbsoluteTimeGetCurrent() - t) * 1000
}
func rowStats() -> (elements: Int, items: Int, walkMs: Double) {
    let t = CFAbsoluteTimeGetCurrent()
    var elements = 0
    var items = Set<String>()
    if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let win = windows.first {
        var stack = [win]
        var guardCount = 0
        while let e = stack.popLast(), guardCount < 40000 {
            guardCount += 1
            elements += 1
            if let ident = attr(e, kAXIdentifierAttribute) as? String, ident.hasPrefix("History.Item.") { items.insert(ident) }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: kids) }
        }
    }
    return (elements, items.count, (CFAbsoluteTimeGetCurrent() - t) * 1000)
}

let wasVisible = panelOnScreen()
let t0 = CFAbsoluteTimeGetCurrent()
if let vk {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)!
        ev.flags = [.maskShift, .maskCommand]
        ev.post(tap: .cghidEventTap)
    }
}
var stateMs = Double.nan
var worst = 0.0
var quietMs = Double.nan
var probes = 0
var fastStreak = 0
let deadline = t0 + timeout
while CFAbsoluteTimeGetCurrent() < deadline {
    if stateMs.isNaN, panelOnScreen() != wasVisible { stateMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
    let ms = cheapProbe()
    probes += 1
    worst = max(worst, ms)
    if !stateMs.isNaN {
        if ms < 10 { fastStreak += 1 } else { fastStreak = 0 }
        if fastStreak >= 3 && quietMs.isNaN { quietMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000; if !countRows { break } }
    }
    if !quietMs.isNaN { break }
    usleep(3000)
}
var extra = ""
if countRows && !wasVisible {
    let s = rowStats()
    extra = String(format: " ax_elements=%d ax_items=%d walk_ms=%.0f", s.elements, s.items, s.walkMs)
}
print(String(format: "%@ %@_ms=%.1f quiet_ms=%.1f worst_probe_ms=%.1f probes=%d%@",
             wasVisible ? "close" : "open", wasVisible ? "hidden" : "visible", stateMs, quietMs, worst, probes, extra))
