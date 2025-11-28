import SwiftUI

/// 字体系统 - 基于 unit 计算
/// 所有字体大小都基于 `ScopySize.unit` 计算，修改 unit 可以缩放整个 UI
enum ScopyTypography {
    private static var u: CGFloat { ScopySize.unit }

    // MARK: - 字体大小
    enum Size {
        private static var u: CGFloat { ScopySize.unit }

        static let micro: CGFloat = u * 2.5     // 10pt - 微小字体
        static let caption: CGFloat = u * 2.75  // 11pt - 说明文字
        static let body: CGFloat = u * 3        // 12pt - 正文
        static let title: CGFloat = u * 3.25    // 13pt - 标题
        static let search: CGFloat = u * 4      // 16pt - 搜索框
    }

    // MARK: - 预定义字体
    static let micro = Font.system(size: Size.micro, weight: .regular)
    static let caption = Font.system(size: Size.caption, weight: .regular)
    static let body = Font.system(size: Size.body, weight: .regular)
    static let title = Font.system(size: Size.title, weight: .medium)
    static let searchField = Font.system(size: Size.search, weight: .light)

    // MARK: - 等宽字体
    static let microMono = Font.system(size: Size.caption, weight: .regular, design: .monospaced)

    // MARK: - 设置页面专用
    static let sidebarLabel = Font.system(size: Size.title, weight: .medium)
    static let pathLabel = Font.system(size: Size.caption, weight: .regular)
}
