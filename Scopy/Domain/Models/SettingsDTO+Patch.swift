import Foundation

public extension SettingsDTO {
    func applying(_ patch: SettingsPatch) -> SettingsDTO {
        var updated = self

        if let value = patch.maxItems { updated.maxItems = value }
        if let value = patch.maxStorageMB { updated.maxStorageMB = value }
        if let value = patch.cleanupImagesOnly { updated.cleanupImagesOnly = value }
        if let value = patch.saveImages { updated.saveImages = value }
        if let value = patch.saveFiles { updated.saveFiles = value }
        if let value = patch.pngquantBinaryPath { updated.pngquantBinaryPath = value }
        if let value = patch.pngquantCopyImageEnabled { updated.pngquantCopyImageEnabled = value }
        if let value = patch.pngquantCopyImageQualityMin { updated.pngquantCopyImageQualityMin = value }
        if let value = patch.pngquantCopyImageQualityMax { updated.pngquantCopyImageQualityMax = value }
        if let value = patch.pngquantCopyImageSpeed { updated.pngquantCopyImageSpeed = value }
        if let value = patch.pngquantCopyImageColors { updated.pngquantCopyImageColors = value }
        if let value = patch.pngquantMarkdownExportEnabled { updated.pngquantMarkdownExportEnabled = value }
        if let value = patch.pngquantMarkdownExportQualityMin { updated.pngquantMarkdownExportQualityMin = value }
        if let value = patch.pngquantMarkdownExportQualityMax { updated.pngquantMarkdownExportQualityMax = value }
        if let value = patch.pngquantMarkdownExportSpeed { updated.pngquantMarkdownExportSpeed = value }
        if let value = patch.pngquantMarkdownExportColors { updated.pngquantMarkdownExportColors = value }
        if let value = patch.clipboardPollingIntervalMs { updated.clipboardPollingIntervalMs = value }
        if let value = patch.defaultSearchMode { updated.defaultSearchMode = value }
        if let value = patch.hotkeyKeyCode { updated.hotkeyKeyCode = value }
        if let value = patch.hotkeyModifiers { updated.hotkeyModifiers = value }
        if let value = patch.showImageThumbnails { updated.showImageThumbnails = value }
        if let value = patch.thumbnailHeight { updated.thumbnailHeight = value }
        if let value = patch.imagePreviewDelay { updated.imagePreviewDelay = value }

        return updated
    }
}
