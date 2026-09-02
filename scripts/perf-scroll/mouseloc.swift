import AppKit
let p = NSEvent.mouseLocation; let h = NSScreen.screens.first!.frame.height
print("mouse (top-left coords): \(Int(p.x)) \(Int(h - p.y))")
