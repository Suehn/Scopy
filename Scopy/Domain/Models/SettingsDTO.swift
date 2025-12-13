import Foundation

/// 设置 DTO
public struct SettingsDTO: Sendable {
    public var maxItems: Int
    public var maxStorageMB: Int
    public var saveImages: Bool
    public var saveFiles: Bool
    public var defaultSearchMode: SearchMode
    public var hotkeyKeyCode: UInt32
    public var hotkeyModifiers: UInt32
    // 缩略图设置 (v0.8)
    public var showImageThumbnails: Bool
    public var thumbnailHeight: Int
    public var imagePreviewDelay: Double  // 悬浮预览延迟（秒）

    public static let `default` = SettingsDTO(
        maxItems: 10000,
        maxStorageMB: 200,
        saveImages: true,
        saveFiles: true,
        defaultSearchMode: .fuzzyPlus,
        hotkeyKeyCode: 8,  // kVK_ANSI_C = 8
        hotkeyModifiers: 0x0300,  // shiftKey (0x0200) | cmdKey (0x0100)
        showImageThumbnails: true,
        thumbnailHeight: 40,
        imagePreviewDelay: 1.0
    )
}
