import AppKit
import ApplicationServices
// usage: axsearch <pid> -> prints the History.SearchField value and the history rows that the pid's panel exposes
// through Accessibility (the terminal must be trusted for Accessibility). Lets the search driver confirm that typed
// text landed and the list changed even when Screen Recording is not granted and screenshots only show the wallpaper.
let pid = Int32(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func texts(_ e: AXUIElement, depth: Int, into out: inout [String]) {
    if depth > 8 || out.count >= 4 { return }
    for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let s = str(e, key), !s.isEmpty { out.append(s.replacingOccurrences(of: "\n", with: " ")); break }
    }
    for c in children(e) { texts(c, depth: depth + 1, into: &out) }
}
var field: AXUIElement?
var rows: [AXUIElement] = []
func walk(_ e: AXUIElement, depth: Int) {
    if depth > 30 { return }
    if str(e, kAXIdentifierAttribute) == "History.SearchField" { field = e }
    let role = str(e, kAXRoleAttribute) ?? ""
    if role == kAXTableRole || role == kAXOutlineRole || role == kAXListRole {
        rows += (attr(e, kAXRowsAttribute) as? [AXUIElement]) ?? []
        return
    }
    for c in children(e) { walk(c, depth: depth + 1) }
}
let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
for w in windows { walk(w, depth: 0) }
print("windows \(windows.count)")
if let field { print("search field value: \"\(str(field, kAXValueAttribute) ?? "")\" focused=\((attr(field, kAXFocusedAttribute) as? Bool) ?? false)") }
else { print("search field: not found") }
print("rows via AX: \(rows.count)")
for r in rows.prefix(5) {
    var t: [String] = []; texts(r, depth: 0, into: &t)
    print("  row:", t.joined(separator: " | ").prefix(120))
}
