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
        case .general: return "通用"
        case .shortcuts: return "快捷键"
        case .clipboard: return "剪贴板"
        case .appearance: return "外观"
        case .storage: return "存储"
        case .about: return "关于"
        }
    }

    var subtitle: String? {
        switch self {
        case .general: return "搜索与默认行为"
        case .shortcuts: return "全局快捷键"
        case .clipboard: return "保存内容类型"
        case .appearance: return "缩略图与预览"
        case .storage: return "容量上限与占用"
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

