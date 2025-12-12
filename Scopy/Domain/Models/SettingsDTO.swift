import Foundation

/// 设置 DTO
struct SettingsDTO: Sendable {
    var maxItems: Int
    var maxStorageMB: Int
    var saveImages: Bool
    var saveFiles: Bool
    var defaultSearchMode: SearchMode
    var hotkeyKeyCode: UInt32
    var hotkeyModifiers: UInt32
    // 缩略图设置 (v0.8)
    var showImageThumbnails: Bool
    var thumbnailHeight: Int
    var imagePreviewDelay: Double  // 悬浮预览延迟（秒）

    static let `default` = SettingsDTO(
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

