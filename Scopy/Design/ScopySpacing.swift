import CoreGraphics

/// 间距系统 - 基于 unit 计算
/// 所有间距都基于 `ScopySize.unit` 计算，修改 unit 可以缩放整个 UI
enum ScopySpacing {
    private static var u: CGFloat { ScopySize.unit }

    static let xxs: CGFloat = u * 0.5   // 2pt - 超小间距
    static let xs: CGFloat = u * 1      // 4pt - 小间距
    static let sm: CGFloat = u * 1.5    // 6pt - 较小间距
    static let md: CGFloat = u * 2      // 8pt - 中等间距
    static let lg: CGFloat = u * 3      // 12pt - 较大间距
    static let xl: CGFloat = u * 4      // 16pt - 大间距
    static let xxl: CGFloat = u * 5     // 20pt - 特大间距
    static let xxxl: CGFloat = u * 8    // 32pt - 超大间距
}
