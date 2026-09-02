import CoreGraphics
// usage: click <x> <y>  -> moves the pointer to (x, y) in top-left screen coordinates and posts a left mouse down/up there.
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let src = CGEventSource(stateID: .hidSystemState)
let p = CGPoint(x: x, y: y)
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    if type != .mouseMoved { ev.setIntegerValueField(.mouseEventClickState, value: 1) }
    ev.post(tap: .cghidEventTap)
    usleep(60_000)
}
print("clicked \(Int(x)) \(Int(y))")
