import AppKit
import SwiftUI

/// Scopy 应用入口点
///
/// 使用独立测试 bundle 模式：
/// - 测试 target 直接编译应用源码（排除 main.swift 和 ScopyApp.swift）
/// - 测试运行时不会启动 SwiftUI App，避免 NSApplication 冲突
/// - 正常运行时启动完整 SwiftUI 应用

ScopyApp.main()
