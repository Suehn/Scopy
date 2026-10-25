import AppKit
import ApplicationServices
import CryptoKit
import Foundation

// Structured observations for the real-app driver. Input events still use perf-scroll's tools.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func emit(_ value: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch { fail("Cannot encode observation: \(error)") }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter {
        attribute($0, kAXRoleAttribute) as? String != kAXMenuBarRole
    }
}

func describe(_ element: AXUIElement, depth: Int = 0, count: inout Int) -> [String: Any] {
    count += 1
    guard depth <= 35, count <= 20000 else { fail("Accessibility tree exceeds the observation bound") }
    var node: [String: Any] = [:]
    for (key, name) in [
        ("role", kAXRoleAttribute), ("id", kAXIdentifierAttribute),
        ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
        ("value", kAXValueAttribute), ("selected", kAXSelectedAttribute),
        ("focused", kAXFocusedAttribute), ("enabled", kAXEnabledAttribute)
    ] {
        if let value = attribute(element, name), value is String || value is NSNumber { node[key] = value }
    }
    if let raw = attribute(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        var point = CGPoint.zero
        if AXValueGetValue(raw as! AXValue, .cgPoint, &point) { node["position"] = [point.x, point.y] }
    }
    if let raw = attribute(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        var size = CGSize.zero
        if AXValueGetValue(raw as! AXValue, .cgSize, &size) { node["size"] = [size.width, size.height] }
    }
    let descendants = children(element)
    if !descendants.isEmpty { node["children"] = descendants.map { describe($0, depth: depth + 1, count: &count) } }
    return node
}

func privatePasteboard(_ name: String) -> NSPasteboard {
    guard name.hasPrefix("ScopyE2E."), name.count > "ScopyE2E.".count else {
        fail("Only a ScopyE2E.* named pasteboard may be read or written")
    }
    return NSPasteboard(name: NSPasteboard.Name(name))
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Expected environment, defaults, pasteboard, general-status or ax command") }
switch command {
case "environment":
    let manager = FileManager.default
    emit([
        "home": NSHomeDirectory(),
        "support": manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).map(\.path),
        "cache": manager.urls(for: .cachesDirectory, in: .userDomainMask).map(\.path),
        "temporary": manager.temporaryDirectory.path,
        "accessibility_trusted": AXIsProcessTrusted(),
        "bundle": Bundle.main.bundleIdentifier ?? NSNull()
    ])
case "defaults":
    guard args.count >= 3, args[1].hasPrefix("com.scopy.e2e.") else { fail("Expected an isolated test defaults domain") }
    let domain = args[1]
    switch args[2] {
    case "read": emit(UserDefaults.standard.persistentDomain(forName: domain) ?? [:])
    case "write":
        guard args.count == 4,
              let data = try? Data(contentsOf: URL(fileURLWithPath: args[3])),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("Expected a JSON defaults dictionary")
        }
        UserDefaults.standard.setPersistentDomain(values, forName: domain)
        UserDefaults.standard.synchronize()
        emit(["written": domain])
    case "remove":
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        emit(["removed": domain])
    default: fail("Unknown defaults operation")
    }
case "general-status":
    // Never request representations from the user's pasteboard, including promised data.
    emit(["change_count": NSPasteboard.general.changeCount])
case "foreground":
    emit(["pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
          "bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
case "activate":
    guard args.count == 2, let pid = Int32(args[1]),
          let app = NSRunningApplication(processIdentifier: pid),
          app.bundleIdentifier?.hasPrefix("com.scopy.e2e.") == true else {
        fail("Expected a running isolated Scopy E2E app")
    }
    _ = app.activate(options: [])
    emit(["pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
case "quit":
    guard args.count == 2, let pid = Int32(args[1]),
          let app = NSRunningApplication(processIdentifier: pid),
          app.bundleIdentifier?.hasPrefix("com.scopy.e2e.") == true else {
        fail("Only an isolated Scopy E2E app may be terminated")
    }
    guard app.terminate() else { fail("Application rejected the quit request") }
    emit(["quit_requested": pid])
case "pasteboard":
    guard args.count >= 3 else { fail("Expected pasteboard <name> write|summary") }
    let pasteboard = privatePasteboard(args[1])
    if args[2] == "write" {
        guard args.count == 4,
              let data = try? Data(contentsOf: URL(fileURLWithPath: args[3])),
              let representations = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            fail("Expected a JSON map of pasteboard type to base64 data")
        }
        let item = NSPasteboardItem()
        for (type, encoded) in representations {
            guard let bytes = Data(base64Encoded: encoded), item.setData(bytes, forType: NSPasteboard.PasteboardType(type)) else {
                fail("Invalid representation for \(type)")
            }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { fail("Pasteboard write failed") }
        emit(["change_count": pasteboard.changeCount])
    } else if args[2] == "summary" {
        var representations: [String: Any] = [:]
        for type in pasteboard.types ?? [] {
            if let bytes = pasteboard.data(forType: type) {
                representations[type.rawValue] = ["bytes": bytes.count,
                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
            }
        }
        emit(["change_count": pasteboard.changeCount, "representations": representations])
    } else { fail("Unknown pasteboard operation") }
case "ax":
    guard args.count >= 2, let pid = Int32(args[1]), AXIsProcessTrusted() else { fail("Expected PID and Accessibility trust") }
    let app = AXUIElementCreateApplication(pid)
    guard args.count == 2 else { fail("Expected ax <pid>; this is an observation-only command") }
    do {
        var count = 0
        let tree = describe(app, count: &count)
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = windowList.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { window -> [String: Any] in
            var result: [String: Any] = [:]
            for key in [kCGWindowNumber, kCGWindowLayer, kCGWindowBounds, kCGWindowName] {
                if let value = window[key as String] { result[key as String] = value }
            }
            return result
        }
        emit(["tree": tree, "windows": windows, "nodes": count])
    }
default: fail("Unknown command \(command)")
}
