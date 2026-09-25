import CoreGraphics

/// Spacing tokens on the ScopySize 4 pt grid.
enum ScopySpacing {
    private static var u: CGFloat { ScopySize.unit }

    static let xxs: CGFloat = u * 0.5
    static let xs: CGFloat = u * 1
    static let sm: CGFloat = u * 1.5
    static let md: CGFloat = u * 2
    static let lg: CGFloat = u * 3
    static let xl: CGFloat = u * 4
}
