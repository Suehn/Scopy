import SwiftUI

// Not @main: main.swift is the entry point so the unit-test target can exclude it.
struct ScopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI apps require a scene, but Scopy owns its status item and
        // windows through AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
