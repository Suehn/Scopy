import AppKit
import CoreGraphics
// Synthetic scroll-wheel driver: posts pixel-precise scrollWheel events to the frontmost window position.
// usage: wheel <x> <y> <deltaPixelsPerEvent> <eventsPerSecond> <durationSeconds> [reverseEverySeconds] [phased]
// Without `phased` the events look like a mouse wheel (no gesture phase, so AppKit posts no live-scroll
// notifications); with `phased` they carry began/changed/ended phases like a trackpad gesture.
let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!, delta = Int32(a[3])!, hz = Double(a[4])!, dur = Double(a[5])!
let flipEvery = a.count > 6 ? Double(a[6])! : 4.0
let phased = a.count > 7 && a[7] == "phased"
let src = CGEventSource(stateID: .hidSystemState)
let phaseField = CGEventField(rawValue: 99)!      // kCGScrollWheelEventScrollPhase
let momentumField = CGEventField(rawValue: 123)!  // kCGScrollWheelEventMomentumPhase
let continuousField = CGEventField(rawValue: 88)! // kCGScrollWheelEventIsContinuous
func post(_ d: Int32, phase: Int64) {
    let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: d, wheel2: 0, wheel3: 0)!
    ev.location = CGPoint(x: x, y: y)
    if phased {
        ev.setIntegerValueField(continuousField, value: 1)
        ev.setIntegerValueField(phaseField, value: phase)
        ev.setIntegerValueField(momentumField, value: 0)
    }
    ev.post(tap: .cghidEventTap)
}
let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
move.post(tap: .cghidEventTap)
usleep(200_000)
let start = CFAbsoluteTimeGetCurrent()
var sent = 0
var sign: Int32 = -1
var lastFlip = start
if phased { post(0, phase: 1) } // began
while CFAbsoluteTimeGetCurrent() - start < dur {
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastFlip >= flipEvery {
        if phased { post(0, phase: 4); post(0, phase: 1) } // ended, began
        sign = -sign; lastFlip = now
    }
    post(sign * delta, phase: 2) // changed
    sent += 1
    let next = start + Double(sent) / hz
    let sleepFor = next - CFAbsoluteTimeGetCurrent()
    if sleepFor > 0 { usleep(UInt32(sleepFor * 1_000_000)) }
}
if phased { post(0, phase: 4) } // ended
print("sent \(sent) \(phased ? "phased " : "")scroll events over \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)) s")
