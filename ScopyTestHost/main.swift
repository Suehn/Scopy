import AppKit

let app = NSApplication.shared
// Real WebKit windows need the AppKit event loop and permission to appear, without a Dock icon.
app.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
