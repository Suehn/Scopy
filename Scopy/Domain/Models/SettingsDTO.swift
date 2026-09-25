import Foundation

/// The transactional settings (Save/Cancel), persisted by SettingsStore.
public struct SettingsDTO: Sendable, Equatable {
    public var maxItems: Int
    public var maxStorageMB: Int
    /// When on, automatic cleanup deletes only image items (and their external payloads), never text or rich text.
    public var cleanupImagesOnly: Bool
    public var saveImages: Bool
    public var saveFiles: Bool
    /// pngquant executable path; empty means the bundled binary is located automatically.
    public var pngquantBinaryPath: String
    /// When on, a captured image is compressed with pngquant before it is written to history; only the compressed image is kept.
    public var pngquantCopyImageEnabled: Bool
    public var pngquantCopyImageQualityMin: Int
    public var pngquantCopyImageQualityMax: Int
    public var pngquantCopyImageSpeed: Int
    public var pngquantCopyImageColors: Int
    /// When on, a Markdown/LaTeX PNG export to the clipboard is compressed with pngquant first; only the compressed PNG is written.
    public var pngquantMarkdownExportEnabled: Bool
    public var pngquantMarkdownExportQualityMin: Int
    public var pngquantMarkdownExportQualityMax: Int
    public var pngquantMarkdownExportSpeed: Int
    public var pngquantMarkdownExportColors: Int
    /// Clipboard polling interval in milliseconds.
    ///
    /// Range: 100ms...2000ms, step 100ms.
    public var clipboardPollingIntervalMs: Int
    public var defaultSearchMode: SearchMode
    public var hotkeyKeyCode: UInt32
    public var hotkeyModifiers: UInt32
    public var showImageThumbnails: Bool
    public var thumbnailHeight: Int
    public var imagePreviewDelay: Double  // seconds
    /// ChatGPT layout scale for Markdown preview and export. It changes font metrics and wrapping only, never the PNG pixel width.
    public var markdownChatGPTLayoutScalePercent: Int
    /// When on, bare links in assistant content (ChatGPT, Codex, ...) fetch an Open Graph title and thumbnail
    /// that are frozen into a local sidecar and rendered as cards. Off by default; the renderer never goes online, this only gates the fetch.
    public var linkEnrichmentEnabled: Bool
    /// Fetch and cache public website icons using origins only.
    public var siteIconsEnabled: Bool = true

    public static let `default` = SettingsDTO(
        maxItems: 10000,
        maxStorageMB: 200,
        cleanupImagesOnly: false,
        saveImages: true,
        saveFiles: true,
        pngquantBinaryPath: "",
        pngquantCopyImageEnabled: false,
        pngquantCopyImageQualityMin: 65,
        pngquantCopyImageQualityMax: 80,
        pngquantCopyImageSpeed: 3,
        pngquantCopyImageColors: 256,
        pngquantMarkdownExportEnabled: true,
        pngquantMarkdownExportQualityMin: 80,
        pngquantMarkdownExportQualityMax: 95,
        pngquantMarkdownExportSpeed: 3,
        pngquantMarkdownExportColors: 256,
        clipboardPollingIntervalMs: 500,
        defaultSearchMode: .fuzzyPlus,
        hotkeyKeyCode: 8,  // kVK_ANSI_C = 8
        hotkeyModifiers: 0x0300,  // shiftKey (0x0200) | cmdKey (0x0100)
        showImageThumbnails: true,
        thumbnailHeight: 40,
        imagePreviewDelay: 1.0,
        markdownChatGPTLayoutScalePercent: MarkdownRenderLayoutConstants.defaultChatGPTLayoutScale.rawValue,
        linkEnrichmentEnabled: false
    )
}
