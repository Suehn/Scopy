import AppKit

final class ScopyTestHostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Intentionally empty: this app exists only as a stable test host.
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.delegate = ScopyTestHostAppDelegate()
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
