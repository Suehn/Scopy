import SwiftUI

// 注意：不使用 @main，改用 main.swift 来支持测试模式
struct ScopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 创建一个隐藏的菜单栏场景（SwiftUI 要求必须有场景）
    @State private var hiddenMenu: Bool = false

    var body: some Scene {
        MenuBarExtra("", isInserted: $hiddenMenu) {
            EmptyView()
        }
    }
}
