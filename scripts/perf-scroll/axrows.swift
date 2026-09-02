import AppKit
import ApplicationServices
// usage: axrows <pid> [maxRows] -> prints the first rows of Scopy's Recent section (after its header) in display order through
// Accessibility:
// section headers by their text, item rows by the uuid from their History.Item.<uuid> identifier, plus any text the row
// exposes (AXValue/AXTitle/AXDescription of descendants). Needs Accessibility trust (build/axcheck) and
// SCOPY_PROFILE_ACCESSIBILITY=1 in the app. Exits 1 when no list is found (panel closed or accessibility hidden).
let pid = Int32(CommandLine.arguments[1])!
let maxRows = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 8
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func find(_ e: AXUIElement, depth: Int, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(e) { return e }
    guard depth > 0 else { return nil }
    for c in children(e) { if let f = find(c, depth: depth - 1, pred) { return f } }
    return nil
}
func collect(_ e: AXUIElement, depth: Int, texts: inout [String], id: inout String) {
    if id.isEmpty, let i = str(e, kAXIdentifierAttribute), i.hasPrefix("History.Item.") { id = String(i.dropFirst("History.Item.".count)) }
    for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let v = attr(e, name) as? String, !v.isEmpty, !texts.contains(v) { texts.append(v.replacingOccurrences(of: "\n", with: "⏎")) }
    }
    guard depth > 0 else { return }
    for c in children(e) { collect(c, depth: depth - 1, texts: &texts, id: &id) }
}
guard let list = find(app, depth: 30, { str($0, kAXIdentifierAttribute) == "History.List" })
        ?? find(app, depth: 30, { [kAXTableRole, kAXOutlineRole].contains(str($0, kAXRoleAttribute) ?? "") }) else {
    print("no history list element (panel closed, or SCOPY_PROFILE_ACCESSIBILITY=1 not set)"); exit(1)
}
var rows = (attr(list, kAXRowsAttribute) as? [AXUIElement]) ?? []
if rows.isEmpty { rows = children(list).filter { str($0, kAXRoleAttribute) == kAXRowRole } }
if rows.isEmpty { rows = children(list) }
// Start at the "Recent" section header (rows before it are the Pinned section); from the top when there is none.
var start = 0
for (i, r) in rows.enumerated() {
    var texts: [String] = [], id = ""
    collect(r, depth: 3, texts: &texts, id: &id)
    if id.isEmpty, texts.contains(where: { $0.hasPrefix("Recent") }) { start = i; break }
}
print("list role \(str(list, kAXRoleAttribute) ?? "?") rows materialized \(rows.count), printing from row \(start)\(start > 0 ? " (rows before it are the Pinned section)" : "")")
for (i, r) in rows.enumerated().dropFirst(start).prefix(maxRows) {
    var texts: [String] = [], id = ""
    collect(r, depth: 14, texts: &texts, id: &id)
    print("row \(i): \(id.isEmpty ? "header" : id) | \(texts.joined(separator: " ⏐ ").prefix(150))")
}
