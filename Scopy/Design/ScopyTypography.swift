import SwiftUI

/// Font tokens on the ScopySize 4 pt grid.
enum ScopyTypography {
    private static var u: CGFloat { ScopySize.unit }

    // MARK: - Sizes
    enum Size {
        private static var u: CGFloat { ScopySize.unit }

        static let micro: CGFloat = u * 2.5
        static let caption: CGFloat = u * 2.75
        static let body: CGFloat = u * 3
        static let title: CGFloat = u * 3.25
        static let search: CGFloat = u * 4
    }

    // MARK: - Fonts
    static let micro = Font.system(size: Size.micro, weight: .regular)
    static let caption = Font.system(size: Size.caption, weight: .regular)
    static let body = Font.system(size: Size.body, weight: .regular)
    static let title = Font.system(size: Size.title, weight: .medium)
    static let searchField = Font.system(size: Size.search, weight: .light)

    // MARK: - Monospaced
    static let microMono = Font.system(size: Size.caption, weight: .regular, design: .monospaced)

    // MARK: - Settings
    static let pathLabel = Font.system(size: Size.caption, weight: .regular)
}
