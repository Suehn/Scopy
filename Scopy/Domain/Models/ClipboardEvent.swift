import Foundation

/// 剪贴板事件 - 对应 v0.md 中的 ClipboardEvent
public enum ClipboardEvent: Sendable {
    case newItem(ClipboardItemDTO)
    case itemUpdated(ClipboardItemDTO)  // 用于置顶更新的条目
    case itemDeleted(UUID)
    case itemPinned(UUID)
    case itemUnpinned(UUID)
    case itemsCleared(keepPinned: Bool)
    case settingsChanged
}
