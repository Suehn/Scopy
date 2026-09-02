import AppKit
import ApplicationServices
import CoreGraphics
// usage: statusclick <pid> -> toggles Scopy's panel the way a user does, by pressing the pid's menu-bar status item.
// Prefers an Accessibility AXPress on the status item (works even when macOS has pushed the item off the menu bar);
// falls back to a real click on the item's on-screen window. Needs Accessibility trust. Exits 1 when nothing is found.
let pid = Int32(CommandLine.arguments[1])!
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
let app = AXUIElementCreateApplication(pid)
if let extras = attr(app, kAXExtrasMenuBarAttribute), CFGetTypeID(extras) == AXUIElementGetTypeID() {
    let bar = extras as! AXUIElement
    if let item = ((attr(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []).first {
        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            print("pressed status item via accessibility"); exit(0)
        }
    }
}
let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == statusLevel,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat], b["Height"]! <= 44, b["Width"]! <= 200 else { continue }
    let p = CGPoint(x: b["X"]! + b["Width"]! / 2, y: b["Y"]! + b["Height"]! / 2)
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    print("clicked status item window at \(Int(p.x)) \(Int(p.y))"); exit(0)
}
print("no status item (accessibility press failed and no on-screen status window)"); exit(1)
