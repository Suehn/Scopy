import Foundation
import ScopyKit

@MainActor
enum HistoryItemMarkdownExportController {
    private static let exportResolutionPercentUserDefaultsKey = "ScopyMarkdownExportResolutionPercent"
    private static let uiTestExportResolutionEnvKey = "SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"

    static func canExportPNG(item: ClipboardItemDTO, filePreviewInfo: FilePreviewInfo?) -> Bool {
        switch item.type {
        case .text, .rtf, .html:
            return MarkdownDetector.isLikelyMarkdown(item.plainText)
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
        resolutionScale: CGFloat? = nil
        ) async -> Result<MarkdownExportService.ExportStats, Error> {
        let html = MarkdownHTMLRenderer.render(markdown: markdownSource)
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

        return await withCheckedContinuation { continuation in
            MarkdownExportService.exportToPNGClipboard(
                html: html,
                targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels,
                resolutionScale: resolutionScale ?? defaultResolutionScale(),
                pngquantOptions: pngquantOptions
            ) { result in
                continuation.resume(returning: result)
            }
        }
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
