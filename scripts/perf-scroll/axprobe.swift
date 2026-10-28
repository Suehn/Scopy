import AppKit
import ApplicationServices
import Foundation

// Content-private AX observations. Row values, titles and descriptions are never requested.
// snapshot: IDs/geometry and optional equality with a controlled search query.
// watch: cached-window role round trips; this includes probe/IPC work, not compositor timing.
let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = Int32(arguments[2]),
      ["snapshot", "watch"].contains(arguments[1]) else {
    fputs("usage: axprobe snapshot <pid> [expectedQuery] | watch <pid> [seconds] [intervalMs]\n", stderr)
    exit(64)
}
guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is required\n", stderr)
    exit(77)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 2)

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func identifier(_ element: AXUIElement) -> String? {
    value(element, kAXIdentifierAttribute) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func bounds(_ element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: point, size: extent)
}

func rowID(_ element: AXUIElement, depth: Int = 0) -> String? {
    if let id = identifier(element), id.hasPrefix("History.Item.") { return id }
    guard depth < 10 else { return nil }
    for child in children(element) {
        if let id = rowID(child, depth: depth + 1) { return id }
    }
    return nil
}

func write(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { exit(70) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

let observationRequested = DispatchTime.now().uptimeNanoseconds
var windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
if arguments[1] == "watch" {
    while !windows.contains(where: { (bounds($0)?.height ?? 0) > 200 }),
          Double(DispatchTime.now().uptimeNanoseconds - observationRequested) / 1e9 < 10 {
        usleep(10_000)
        windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
}
guard let window = windows.first(where: { (bounds($0)?.height ?? 0) > 200 }) else {
    write(["valid": false, "reason": "no_application_window"])
    exit(2)
}

if arguments[1] == "snapshot" {
    let started = DispatchTime.now().uptimeNanoseconds
    var field: AXUIElement?
    var list: AXUIElement?
    func locate(_ element: AXUIElement, depth: Int) {
        guard depth < 20 else { return }
        let id = identifier(element)
        if id == "History.SearchField" { field = element; return }
        if id == "History.List" { list = element; return }
        for child in children(element) { locate(child, depth: depth + 1) }
    }
    locate(window, depth: 0)
    let rows = list.flatMap { value($0, kAXRowsAttribute) as? [AXUIElement] } ?? []
    let windowBounds = bounds(window) ?? .zero
    var visible: [[String: Any]] = []
    for row in rows {
        guard let frame = bounds(row), !frame.isEmpty, frame.intersects(windowBounds),
              let id = rowID(row) else { continue }
        visible.append(["id": id, "x": frame.origin.x, "y": frame.origin.y,
                        "width": frame.width, "height": frame.height])
        if visible.count >= 64 { break }
    }
    var payload: [String: Any] = ["valid": field != nil && list != nil, "row_count": rows.count,
                                 "visible_rows": visible, "window_count": windows.count,
                                 "observation_start_ns": started,
                                 "observation_end_ns": DispatchTime.now().uptimeNanoseconds]
    if arguments.count >= 4, let field {
        payload["query_matches"] = (value(field, kAXValueAttribute) as? String) == arguments[3]
    }
    write(payload)
    exit(field != nil && list != nil ? 0 : 2)
}

let seconds = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 5
let intervalMs = arguments.count > 4 ? Double(arguments[4]) ?? 0 : 10
let stopFile = arguments.count > 5 ? arguments[5] : nil
guard seconds > 0, seconds <= 180, intervalMs >= 3, intervalMs <= 1000 else { exit(64) }
var warmValue: CFTypeRef?
_ = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &warmValue)
let started = DispatchTime.now().uptimeNanoseconds
var observations: [[String: Any]] = []
var durations: [Double] = []
var errorCount = 0
while Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < seconds {
    if let stopFile, FileManager.default.fileExists(atPath: stopFile) { break }
    let before = DispatchTime.now().uptimeNanoseconds
    var role: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
    let after = DispatchTime.now().uptimeNanoseconds
    let elapsedMs = Double(after - before) / 1e6
    observations.append(["start_ns": before, "end_ns": after, "roundtrip_ms": elapsedMs, "ax_error": error.rawValue])
    durations.append(elapsedMs)
    if error != .success { errorCount += 1 }
    usleep(UInt32(intervalMs * 1000))
}
let sorted = durations.sorted()
guard !sorted.isEmpty else {
    write(["valid": false, "reason": "no_completed_probes"])
    exit(2)
}
func percentile(_ fraction: Double) -> Double {
    sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}
write(["valid": errorCount == 0 && !durations.isEmpty, "probe": "cached_window_role",
       "scope": "AX round trip including IPC and probe work; not pure main-thread stall or presented frames",
       "observation_requested_ns": observationRequested, "probe_started_ns": started,
       "interval_ms": intervalMs, "error_count": errorCount, "samples": observations,
       "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "max_ms": sorted[sorted.count - 1]])
exit(errorCount == 0 ? 0 : 2)
