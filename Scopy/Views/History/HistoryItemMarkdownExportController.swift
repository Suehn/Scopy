import Foundation
import ScopyKit

@MainActor
enum HistoryItemMarkdownExportController {
    private static let exportResolutionPercentUserDefaultsKey = "ScopyMarkdownExportResolutionPercent"
    private static let uiTestExportResolutionEnvKey = "SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"

    static func canOfferPNGMenuItem(item: ClipboardItemDTO, filePreviewInfo: FilePreviewInfo?) -> Bool {
        canOfferPNGMenuItem(
            item: item,
            contentRevision: ClipboardItemContentRevision(item: item),
            filePreviewInfo: filePreviewInfo
        )
    }

    /// Hot-path overload for rows that already own the deterministic content revision.
    static func canOfferPNGMenuItem(
        item: ClipboardItemDTO,
        contentRevision: ClipboardItemContentRevision,
        filePreviewInfo: FilePreviewInfo?
    ) -> Bool {
        switch item.type {
        case .text, .rtf, .html:
            if let cached = HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(
                for: contentRevision
            ) {
                return cached
            }
            return HistoryItemPresentationCache.shared.markdownMenuSignal(
                for: contentRevision,
                plainText: item.plainText
            )
        case .file:
            guard let info = filePreviewInfo else { return false }
            return FilePreviewSupport.isMarkdownFile(info.url)
        default:
            return false
        }
    }

    static func canExportPNG(item: ClipboardItemDTO, filePreviewInfo: FilePreviewInfo?) -> Bool {
        switch item.type {
        case .text, .rtf, .html:
            return HistoryItemPresentationCache.shared.markdownExportCapability(for: item)
        case .file:
            guard let info = filePreviewInfo else { return false }
            return FilePreviewSupport.isMarkdownFile(info.url)
        default:
            return false
        }
    }

    static func defaultResolutionScale() -> CGFloat {
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("--uitesting"),
           let percent = parseExportResolutionPercent(from: processInfo.environment[uiTestExportResolutionEnvKey]) {
            return CGFloat(percent) / 100
        }

        let stored = UserDefaults.standard.integer(forKey: exportResolutionPercentUserDefaultsKey)
        let percent = [100, 150, 200].contains(stored) ? stored : 100
        return CGFloat(percent) / 100
    }

    static func loadMarkdownSource(item: ClipboardItemDTO, filePreviewInfo: FilePreviewInfo?) async -> String? {
        switch item.type {
        case .text, .rtf, .html:
            let source = item.plainText.trimmingCharacters(in: .newlines)
            return source.isEmpty ? nil : item.plainText
        case .file:
            guard let info = filePreviewInfo, FilePreviewSupport.isMarkdownFile(info.url) else { return nil }
            return await Task.detached(priority: .utility) {
                if let utf8 = try? String(contentsOf: info.url, encoding: .utf8) {
                    return utf8
                }
                if let utf16 = try? String(contentsOf: info.url, encoding: .utf16) {
                    return utf16
                }
                guard let data = try? Data(contentsOf: info.url, options: [.mappedIfSafe]) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }.value
        default:
            return nil
        }
    }

    static func exportMarkdownToClipboard(
        markdownSource: String,
        settings: SettingsDTO,
        layoutScale: MarkdownChatGPTLayoutScalePercent? = nil,
        resolutionScale: CGFloat? = nil,
        pasteboardWriteLease: MarkdownExportService.PasteboardWriteLease? = nil,
        authorizePasteboardWrite: @escaping @MainActor () -> Bool = { true }
        ) async -> Result<MarkdownExportService.ExportStats, Error> {
        let resolvedLayoutScale = layoutScale ?? MarkdownChatGPTLayoutScalePercent(
            settingsValue: settings.markdownChatGPTLayoutScalePercent
        )
        let context = MarkdownRenderContextResolver.defaultContext(
            for: markdownSource,
            layoutScale: resolvedLayoutScale
        )
        let html = MarkdownHTMLRenderer.render(markdown: markdownSource, context: context).html
        let pngquantOptions: PngquantService.Options? = {
            guard settings.pngquantMarkdownExportEnabled else { return nil }
            return PngquantService.Options(
                binaryPath: settings.pngquantBinaryPath,
                qualityMin: settings.pngquantMarkdownExportQualityMin,
                qualityMax: settings.pngquantMarkdownExportQualityMax,
                speed: settings.pngquantMarkdownExportSpeed,
                colors: settings.pngquantMarkdownExportColors
            )
        }()

        let cancellationRelay = MarkdownExportCancellationRelay()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let handle = MarkdownExportService.exportToPNGClipboard(
                    html: html,
                    targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels,
                    resolutionScale: resolutionScale ?? defaultResolutionScale(),
                    pngquantOptions: pngquantOptions,
                    pasteboardWriteLease: pasteboardWriteLease,
                    authorizePasteboardWrite: authorizePasteboardWrite
                ) { result in
                    continuation.resume(returning: result)
                }
                cancellationRelay.install(handle)
            }
        }, onCancel: {
            cancellationRelay.cancel()
        })
    }

    private static func parseExportResolutionPercent(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let noSuffix: String
        if lowered.hasSuffix("x") {
            noSuffix = String(lowered.dropLast())
        } else {
            noSuffix = lowered
        }

        if let percent = Int(noSuffix), [100, 150, 200].contains(percent) {
            return percent
        }
        if let multiplier = Double(noSuffix) {
            let percent = Int(round(multiplier * 100))
            if [100, 150, 200].contains(percent) {
                return percent
            }
        }
        return nil
    }
}

private final class MarkdownExportCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: MarkdownExportService.CancellationHandle?
    private var cancellationRequested = false

    func install(_ handle: MarkdownExportService.CancellationHandle) {
        lock.lock()
        if cancellationRequested {
            lock.unlock()
            Task { @MainActor in handle.cancel() }
            return
        }
        self.handle = handle
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let handle = self.handle
        self.handle = nil
        lock.unlock()

        guard let handle else { return }
        Task { @MainActor in handle.cancel() }
    }
}
