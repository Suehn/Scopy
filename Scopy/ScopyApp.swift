import SwiftUI

// 注意：不使用 @main，改用 main.swift 来支持测试模式
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
