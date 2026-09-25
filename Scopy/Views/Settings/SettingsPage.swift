import Foundation

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case shortcuts
    case clipboard
    case appearance
    case storage
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .shortcuts: return String(localized: "Shortcuts")
        case .clipboard: return String(localized: "Clipboard")
        case .appearance: return String(localized: "Appearance")
        case .storage: return String(localized: "Storage")
        case .about: return String(localized: "About")
        }
    }

    var subtitle: String? {
        switch self {
        case .general: return String(localized: "Search and startup")
        case .shortcuts: return String(localized: "Global hotkey")
        case .clipboard: return String(localized: "Captured content types")
        case .appearance: return String(localized: "Thumbnails and previews")
        case .storage: return String(localized: "Limits and usage")
        case .about: return nil
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .appearance: return "paintpalette"
        case .storage: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}

