import AppKit
import CoreGraphics
// Synthetic scroll-wheel driver: posts pixel-precise scrollWheel events to the frontmost window position.
// usage: wheel <x> <y> <deltaPixelsPerEvent> <eventsPerSecond> <durationSeconds> [reverseEverySeconds]
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!, delta = Int32(a[3])!, hz = Double(a[4])!, dur = Double(a[5])!
let flipEvery = a.count > 6 ? Double(a[6])! : 4.0
let src = CGEventSource(stateID: .hidSystemState)
let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
move.post(tap: .cghidEventTap)
usleep(200_000)
let start = CFAbsoluteTimeGetCurrent()
var sent = 0
var sign: Int32 = -1
var lastFlip = start
while CFAbsoluteTimeGetCurrent() - start < dur {
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastFlip >= flipEvery { sign = -sign; lastFlip = now }
    let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: sign * delta, wheel2: 0, wheel3: 0)!
    ev.location = CGPoint(x: x, y: y)
    ev.post(tap: .cghidEventTap)
    sent += 1
    let next = start + Double(sent) / hz
    let sleepFor = next - CFAbsoluteTimeGetCurrent()
    if sleepFor > 0 { usleep(UInt32(sleepFor * 1_000_000)) }
}
print("sent \(sent) scroll events over \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)) s")
