import CoreGraphics

/// Size tokens on a 4 pt grid; views outside ScopySize still use literal sizes.
enum ScopySize {
    // MARK: - Grid unit
    static let unit: CGFloat = 4

    // MARK: - Icons
    enum Icon {
        private static var u: CGFloat { ScopySize.unit }

        static let xs: CGFloat = u * 3
        static let sm: CGFloat = u * 4
        static let md: CGFloat = u * 5
        static let lg: CGFloat = u * 6
        static let xl: CGFloat = u * 8

        static let header: CGFloat = u * 4.5
        static let filter: CGFloat = u * 4
        static let listApp: CGFloat = u * 5
        static let menuApp: CGFloat = u * 4.5
        static let pin: CGFloat = u * 2.5
        static let empty: CGFloat = u * 5
        static let appLogo: CGFloat = u * 12
    }

    // MARK: - Corner radii
    enum Corner {
        private static var u: CGFloat { ScopySize.unit }

        static let xs: CGFloat = u * 0.5
        static let sm: CGFloat = u * 1
        static let md: CGFloat = u * 1.5
        static let lg: CGFloat = u * 2
        static let xl: CGFloat = u * 2.5
    }

    // MARK: - Heights
    enum Height {
        private static var u: CGFloat { ScopySize.unit }

        static let listItem: CGFloat = u * 9
        /// Laid-out height of a text history row. The history List estimates rows it has not
        /// laid out yet at this height; see `HistoryListView`.
        static let listRowEstimate: CGFloat = 43
        static let header: CGFloat = u * 11
        static let footer: CGFloat = u * 8
        static let loadMore: CGFloat = u * 7.5
        static let divider: CGFloat = u * 4
        static let pinIndicator: CGFloat = u * 5
    }

    // MARK: - Widths
    enum Width {
        private static var u: CGFloat { ScopySize.unit }

        static let pinIndicator: CGFloat = u * 0.75
        static let settingsLabel: CGFloat = u * 30
        static let statLabel: CGFloat = u * 12.5
        static let sidebarMin: CGFloat = u * 55
        static let pickerMenu: CGFloat = u * 30
        static let previewMax: CGFloat = u * 160
    }

    // MARK: - Windows
    enum Window {
        private static var u: CGFloat { ScopySize.unit }

        static let mainWidth: CGFloat = u * 120
        static let mainHeight: CGFloat = u * 160
        static let settingsWidth: CGFloat = u * 180
        static let settingsHeight: CGFloat = u * 130
    }

    // MARK: - Strokes
    enum Stroke {
        static let thin: CGFloat = 0.5
        static let normal: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let thick: CGFloat = 2
    }

    // MARK: - Opacity
    enum Opacity {
        static let subtle: CGFloat = 0.1
        static let light: CGFloat = 0.3
        static let medium: CGFloat = 0.5
        static let strong: CGFloat = 0.8
    }
}
