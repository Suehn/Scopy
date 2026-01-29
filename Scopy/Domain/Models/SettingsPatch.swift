import Foundation

/// A field-level patch for `SettingsDTO`.
///
/// Notes:
/// - This is used to merge settings updates without accidentally overwriting concurrently updated fields.
/// - Each property is `nil` when unchanged from the baseline.
public struct SettingsPatch: Sendable, Equatable {
    public var maxItems: Int?
    public var maxStorageMB: Int?
    public var cleanupImagesOnly: Bool?
    public var saveImages: Bool?
    public var saveFiles: Bool?
    public var pngquantBinaryPath: String?
    public var pngquantCopyImageEnabled: Bool?
    public var pngquantCopyImageQualityMin: Int?
    public var pngquantCopyImageQualityMax: Int?
    public var pngquantCopyImageSpeed: Int?
    public var pngquantCopyImageColors: Int?
    public var pngquantMarkdownExportEnabled: Bool?
    public var pngquantMarkdownExportQualityMin: Int?
    public var pngquantMarkdownExportQualityMax: Int?
    public var pngquantMarkdownExportSpeed: Int?
    public var pngquantMarkdownExportColors: Int?
    public var clipboardPollingIntervalMs: Int?
    public var defaultSearchMode: SearchMode?
    public var hotkeyKeyCode: UInt32?
    public var hotkeyModifiers: UInt32?
    public var showImageThumbnails: Bool?
    public var thumbnailHeight: Int?
    public var imagePreviewDelay: Double?

    public static func from(baseline: SettingsDTO, draft: SettingsDTO) -> SettingsPatch {
        var patch = SettingsPatch()

        if draft.maxItems != baseline.maxItems { patch.maxItems = draft.maxItems }
        if draft.maxStorageMB != baseline.maxStorageMB { patch.maxStorageMB = draft.maxStorageMB }
        if draft.cleanupImagesOnly != baseline.cleanupImagesOnly { patch.cleanupImagesOnly = draft.cleanupImagesOnly }
        if draft.saveImages != baseline.saveImages { patch.saveImages = draft.saveImages }
        if draft.saveFiles != baseline.saveFiles { patch.saveFiles = draft.saveFiles }
        if draft.pngquantBinaryPath != baseline.pngquantBinaryPath { patch.pngquantBinaryPath = draft.pngquantBinaryPath }
        if draft.pngquantCopyImageEnabled != baseline.pngquantCopyImageEnabled { patch.pngquantCopyImageEnabled = draft.pngquantCopyImageEnabled }
        if draft.pngquantCopyImageQualityMin != baseline.pngquantCopyImageQualityMin { patch.pngquantCopyImageQualityMin = draft.pngquantCopyImageQualityMin }
        if draft.pngquantCopyImageQualityMax != baseline.pngquantCopyImageQualityMax { patch.pngquantCopyImageQualityMax = draft.pngquantCopyImageQualityMax }
        if draft.pngquantCopyImageSpeed != baseline.pngquantCopyImageSpeed { patch.pngquantCopyImageSpeed = draft.pngquantCopyImageSpeed }
        if draft.pngquantCopyImageColors != baseline.pngquantCopyImageColors { patch.pngquantCopyImageColors = draft.pngquantCopyImageColors }
        if draft.pngquantMarkdownExportEnabled != baseline.pngquantMarkdownExportEnabled { patch.pngquantMarkdownExportEnabled = draft.pngquantMarkdownExportEnabled }
        if draft.pngquantMarkdownExportQualityMin != baseline.pngquantMarkdownExportQualityMin { patch.pngquantMarkdownExportQualityMin = draft.pngquantMarkdownExportQualityMin }
        if draft.pngquantMarkdownExportQualityMax != baseline.pngquantMarkdownExportQualityMax { patch.pngquantMarkdownExportQualityMax = draft.pngquantMarkdownExportQualityMax }
        if draft.pngquantMarkdownExportSpeed != baseline.pngquantMarkdownExportSpeed { patch.pngquantMarkdownExportSpeed = draft.pngquantMarkdownExportSpeed }
        if draft.pngquantMarkdownExportColors != baseline.pngquantMarkdownExportColors { patch.pngquantMarkdownExportColors = draft.pngquantMarkdownExportColors }
        if draft.clipboardPollingIntervalMs != baseline.clipboardPollingIntervalMs { patch.clipboardPollingIntervalMs = draft.clipboardPollingIntervalMs }
        if draft.defaultSearchMode != baseline.defaultSearchMode { patch.defaultSearchMode = draft.defaultSearchMode }
        if draft.hotkeyKeyCode != baseline.hotkeyKeyCode { patch.hotkeyKeyCode = draft.hotkeyKeyCode }
        if draft.hotkeyModifiers != baseline.hotkeyModifiers { patch.hotkeyModifiers = draft.hotkeyModifiers }
        if draft.showImageThumbnails != baseline.showImageThumbnails { patch.showImageThumbnails = draft.showImageThumbnails }
        if draft.thumbnailHeight != baseline.thumbnailHeight { patch.thumbnailHeight = draft.thumbnailHeight }
        if draft.imagePreviewDelay != baseline.imagePreviewDelay { patch.imagePreviewDelay = draft.imagePreviewDelay }

        return patch
    }

    public func droppingHotkey() -> SettingsPatch {
        var copy = self
        copy.hotkeyKeyCode = nil
        copy.hotkeyModifiers = nil
        return copy
    }

    public var isEmpty: Bool {
        maxItems == nil
            && maxStorageMB == nil
            && cleanupImagesOnly == nil
            && saveImages == nil
            && saveFiles == nil
            && pngquantBinaryPath == nil
            && pngquantCopyImageEnabled == nil
            && pngquantCopyImageQualityMin == nil
            && pngquantCopyImageQualityMax == nil
            && pngquantCopyImageSpeed == nil
            && pngquantCopyImageColors == nil
            && pngquantMarkdownExportEnabled == nil
            && pngquantMarkdownExportQualityMin == nil
            && pngquantMarkdownExportQualityMax == nil
            && pngquantMarkdownExportSpeed == nil
            && pngquantMarkdownExportColors == nil
            && clipboardPollingIntervalMs == nil
            && defaultSearchMode == nil
            && hotkeyKeyCode == nil
            && hotkeyModifiers == nil
            && showImageThumbnails == nil
            && thumbnailHeight == nil
            && imagePreviewDelay == nil
    }
}
