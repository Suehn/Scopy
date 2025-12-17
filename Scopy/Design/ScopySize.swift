import CoreGraphics

/// 智能尺寸系统 - 基于基础值 + 偏移量计算
/// 所有尺寸都基于 `unit` 计算，修改 unit 可以缩放整个 UI
enum ScopySize {
    // MARK: - 基础单位（4pt 网格系统）
    static let unit: CGFloat = 4

    // MARK: - 图标尺寸
    enum Icon {
        private static var u: CGFloat { ScopySize.unit }

        static let xs: CGFloat = u * 3       // 12pt - 小图标
        static let sm: CGFloat = u * 4       // 16pt - 标准小图标
        static let md: CGFloat = u * 5       // 20pt - 列表项图标
        static let lg: CGFloat = u * 6       // 24pt - 大图标
        static let xl: CGFloat = u * 8       // 32pt - 特大图标

        // 特定场景
        static let header: CGFloat = u * 4.5   // 18pt - Header 搜索图标
        static let filter: CGFloat = u * 4     // 16pt - 过滤按钮图标
        static let listApp: CGFloat = u * 5    // 20pt - 列表 App 图标
        static let menuApp: CGFloat = u * 4.5  // 18pt - 菜单 App 图标
        static let pin: CGFloat = u * 2.5      // 10pt - Pin 图标
        static let empty: CGFloat = u * 5      // 20pt - 空状态图标
        static let appLogo: CGFloat = u * 12   // 48pt - App Logo
    }

    // MARK: - 圆角
    enum Corner {
        private static var u: CGFloat { ScopySize.unit }

        static let xs: CGFloat = u * 0.5   // 2pt
        static let sm: CGFloat = u * 1     // 4pt
        static let md: CGFloat = u * 1.5   // 6pt
        static let lg: CGFloat = u * 2     // 8pt
        static let xl: CGFloat = u * 2.5   // 10pt
    }

    // MARK: - 组件高度
    enum Height {
        private static var u: CGFloat { ScopySize.unit }

        static let listItem: CGFloat = u * 9      // 36pt - 列表项最小高度
        static let header: CGFloat = u * 11       // 44pt - Header 高度
        static let footer: CGFloat = u * 8        // 32pt - Footer 高度
        static let loadMore: CGFloat = u * 7.5    // 30pt - 加载更多高度
        static let divider: CGFloat = u * 4       // 16pt - 分隔线高度
        static let pinIndicator: CGFloat = u * 5  // 20pt - Pin 指示条高度
    }

    // MARK: - 宽度
    enum Width {
        private static var u: CGFloat { ScopySize.unit }

        static let pinIndicator: CGFloat = u * 0.75   // 3pt - Pin 指示条宽度
        static let settingsLabel: CGFloat = u * 30    // 120pt - 设置标签宽度
        static let statLabel: CGFloat = u * 12.5      // 50pt - 统计标签宽度
        static let sidebarMin: CGFloat = u * 55       // 220pt - 侧边栏最小宽度
        static let pickerMenu: CGFloat = u * 30       // 120pt - Picker 菜单宽度
        static let previewMax: CGFloat = u * 160      // 640pt - 预览最大宽度
    }

    // MARK: - 窗口尺寸
    enum Window {
        private static var u: CGFloat { ScopySize.unit }

        static let mainWidth: CGFloat = u * 105       // 420pt
        static let mainHeight: CGFloat = u * 160      // 640pt
        static let settingsWidth: CGFloat = u * 180   // 720pt
        static let settingsHeight: CGFloat = u * 130  // 520pt
    }

    // MARK: - 边框宽度
    enum Stroke {
        static let thin: CGFloat = 0.5      // 细边框
        static let normal: CGFloat = 1      // 标准边框
        static let medium: CGFloat = 1.5    // 中等边框（选中态）
        static let thick: CGFloat = 2       // 粗边框
    }

    // MARK: - 透明度
    enum Opacity {
        static let subtle: CGFloat = 0.1    // 微弱
        static let light: CGFloat = 0.3     // 轻
        static let medium: CGFloat = 0.5    // 中等
        static let strong: CGFloat = 0.8    // 强
    }
}
