import Foundation

enum Localization {
    /// The one byte formatter for every user-visible size (row metadata, footer, storage stats):
    /// Finder-style 1000-based units in the user's locale, never a bare byte count.
    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

