import AppKit
import CoreGraphics
// usage: winpos <pid> [--activate]  -> prints "x y w h" of the pid's largest on-screen window, after verifying that the
// window's center is not covered by another process's window. Exits 2 when covered, 1 when no window.
let pid = Int32(CommandLine.arguments[1])!
let activate = CommandLine.arguments.contains("--activate")
if activate, let app = NSRunningApplication(processIdentifier: pid) {
    app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    usleep(400_000)
}
func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
let list = windows()  // front-to-back order
// Prefer the floating panel over any ordinary window the app also has on screen: the panel is at the
// status-bar window level, and picking a larger ordinary window instead silently produces runs where
// the synthetic input never reaches the list.
var best: (Int, CGFloat, [String: CGFloat])? = nil
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"], width > 100, height > 100 else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let area = width * height
    if best == nil || layer > best!.0 || (layer == best!.0 && area > best!.1) { best = (layer, area, b) }
}
guard let b = best?.2 else { print("none"); exit(1) }
let cx = b["X"]! + b["Width"]! / 2, cy = b["Y"]! + b["Height"]! / 2 + 40
for w in list {
    guard let wb = w[kCGWindowBounds as String] as? [String: CGFloat], let layer = w[kCGWindowLayer as String] as? Int, layer < 1000 else { continue }
    if let owner = w[kCGWindowOwnerName as String] as? String, owner == "Window Server" || owner == "Dock" { continue }
    let rect = CGRect(x: wb["X"]!, y: wb["Y"]!, width: wb["Width"]!, height: wb["Height"]!)
    if rect.contains(CGPoint(x: cx, y: cy)) {
        if (w[kCGWindowOwnerPID as String] as? Int32) == pid { break }
        print("covered by pid \(w[kCGWindowOwnerPID as String] ?? 0) \(w[kCGWindowOwnerName as String] ?? "")"); exit(2)
    }
}
print("\(Int(b["X"]!)) \(Int(b["Y"]!)) \(Int(b["Width"]!)) \(Int(b["Height"]!))")
