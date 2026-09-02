import CoreGraphics
let x = Double(CommandLine.arguments[1])!, y = Double(CommandLine.arguments[2])!
let r = CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
print("warp result", r.rawValue)
