import SwiftUI

/// 设计系统字体层级
/// v0.10.3: 调整字体大小以提升可读性
enum ScopyTypography {
    static let title = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    // v0.10.3: 从 10pt 调整到 11pt 提升可读性
    static let microMono = Font.system(size: 11, weight: .regular, design: .monospaced)
    // 搜索框专用字体
    static let searchField = Font.system(size: 16, weight: .light)
}

