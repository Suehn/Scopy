import AppKit
import CoreGraphics
// Synthetic typing driver: posts a key-down and a key-up CGEvent per character at a fixed pace.
// usage: typekeys <charsPerSecond> <text...>   (arguments after the rate are joined with single spaces)
// Every character goes out as virtual key 0 with the Unicode string attached, so any Unicode text works.
// Tokens: <bs> = backspace (virtual key 51), <cmd-a> = select all (Command + virtual key 0).
let a = CommandLine.arguments
guard a.count >= 3, let rate = Double(a[1]), rate > 0 else {
    print("usage: typekeys <charsPerSecond> <text...>"); exit(64)
}
let text = a[2...].joined(separator: " ")
enum Key { case char(Character), backspace, selectAll }
var keys: [Key] = []
var rest = Substring(text)
while let c = rest.first {
    if rest.hasPrefix("<bs>") { keys.append(.backspace); rest = rest.dropFirst(4) }
    else if rest.hasPrefix("<cmd-a>") { keys.append(.selectAll); rest = rest.dropFirst(7) }
    else { keys.append(.char(c)); rest = rest.dropFirst() }
}
let src = CGEventSource(stateID: .hidSystemState)
var sent = 0
func post(_ key: Key) {
    var vk: CGKeyCode = 0
    var flags: CGEventFlags = []
    if case .backspace = key { vk = 51 }
    if case .selectAll = key { flags = .maskCommand }
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)!
        ev.flags = flags
        if case .char(let c) = key {
            var units = Array(String(c).utf16)
            ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        ev.post(tap: .cghidEventTap)
        sent += 1
    }
}
let start = CFAbsoluteTimeGetCurrent()
for (i, key) in keys.enumerated() {
    post(key)
    let next = start + Double(i + 1) / rate
    let sleepFor = next - CFAbsoluteTimeGetCurrent()
    if sleepFor > 0 { usleep(UInt32(sleepFor * 1_000_000)) }
}
print("sent \(sent) key events (\(keys.count) keys at \(rate)/s) over \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start)) s")
