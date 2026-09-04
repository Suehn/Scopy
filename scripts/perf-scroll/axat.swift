import AppKit
import ApplicationServices
// usage: axat <pid> <x> <y> -> prints the text of the deepest accessibility element at a screen
// point, plus the text of any other window the app has on screen (a hover preview). Used to check
// that a hover opens the preview belonging to the row actually under the pointer.
let pid = Int32(CommandLine.arguments[1])!
let x = Double(CommandLine.arguments[2])!, y = Double(CommandLine.arguments[3])!
let system = AXUIElementCreateSystemWide()
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func texts(_ e: AXUIElement, _ depth: Int, into out: inout [String]) {
    for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let v = attr(e, name) as? String, v.count > 3, !out.contains(v) { out.append(v) }
    }
    guard depth > 0 else { return }
    for c in kids(e) { texts(c, depth - 1, into: &out) }
}
var element: AXUIElement?
if AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &element) == .success, let element {
    var owner: pid_t = 0
    AXUIElementGetPid(element, &owner)
    var out: [String] = []
    texts(element, 3, into: &out)
    print("at-point pid=\(owner) \(out.prefix(3).joined(separator: " | ").prefix(160))")
} else {
    print("at-point none")
}
let app = AXUIElementCreateApplication(pid)
let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
print("windows=\(windows.count)")
for (i, w) in windows.enumerated() {
    var out: [String] = []
    texts(w, 6, into: &out)
    print("window\(i): \(out.prefix(4).joined(separator: " | ").prefix(200))")
}
