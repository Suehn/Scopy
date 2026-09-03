import AppKit
import ApplicationServices
import CoreGraphics
// Measures main-thread stalls caused by pointing at history rows.
// usage: hoverstall <pid> <x> <y> [--seconds 4] [--move N] [--step 40]
// Moves the pointer onto a row (optionally stepping down N further rows) and, throughout, issues a cheap
// constant-cost Accessibility query every ~5 ms. Those queries are answered on the app's main thread, so a
// slow answer means the main thread was blocked that long. Prints every stall over 50 ms with its offset.
let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[1]), let x = Double(args[2]), let y = Double(args[3]) else {
    print("usage: hoverstall <pid> <x> <y>"); exit(64)
}
let seconds = args.firstIndex(of: "--seconds").map { Double(args[$0 + 1]) ?? 4 } ?? 4
let moves = args.firstIndex(of: "--move").map { Int(args[$0 + 1]) ?? 0 } ?? 0
let step = args.firstIndex(of: "--step").map { Double(args[$0 + 1]) ?? 40 } ?? 40
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)
func probe() -> Double {
    let t = CFAbsoluteTimeGetCurrent()
    if let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement], let win = windows.first { _ = attr(win, kAXRoleAttribute) }
    return (CFAbsoluteTimeGetCurrent() - t) * 1000
}
func move(_ p: CGPoint) {
    CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
}
_ = probe()   // warm the connection
let t0 = CFAbsoluteTimeGetCurrent()
var stalls: [(Double, Double)] = []
var samples: [Double] = []
var nextMove = 0
let moveInterval = moves > 0 ? seconds / Double(moves + 1) : .infinity
move(CGPoint(x: x, y: y))
while CFAbsoluteTimeGetCurrent() - t0 < seconds {
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    if moves > 0, elapsed > Double(nextMove + 1) * moveInterval, nextMove < moves {
        nextMove += 1
        move(CGPoint(x: x, y: y + Double(nextMove) * step))
    }
    let ms = probe()
    samples.append(ms)
    if ms > 50 { stalls.append((elapsed * 1000, ms)) }
    usleep(3000)
}
let sorted = samples.sorted()
func pct(_ q: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
print(String(format: "probes=%d p50=%.1f p95=%.1f max=%.1f stalls>50ms=%d blocked_ms=%.0f",
             samples.count, pct(0.5), pct(0.95), sorted.last ?? .nan, stalls.count, stalls.reduce(0) { $0 + $1.1 }))
for (at, ms) in stalls.prefix(12) { print(String(format: "  stall at %.0f ms: %.0f ms", at, ms)) }
