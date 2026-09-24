import AppKit
import Foundation

extension ClipboardMonitor {
    /// 原始剪贴板数据（在主线程提取，但哈希计算延迟到后台）
    struct RawClipboardData: Sendable {
        let type: ClipboardItemType
        let plainText: String
        let rawData: Data?
        let appBundleID: String?
        let sizeBytes: Int
        let precomputedHash: String?  // 图片等内容的预计算轻量指纹
        let imageDataWasTIFF: Bool

        init(
            type: ClipboardItemType,
            plainText: String,
            rawData: Data?,
            appBundleID: String?,
            sizeBytes: Int,
            precomputedHash: String? = nil,
            imageDataWasTIFF: Bool = false
        ) {
            self.type = type
            self.plainText = plainText
            self.rawData = rawData
            self.appBundleID = appBundleID
            self.sizeBytes = sizeBytes
            self.precomputedHash = precomputedHash
            self.imageDataWasTIFF = imageDataWasTIFF
        }
    }

    /// Outcome of reading one pasteboard change.
    enum Extraction {
        case content(RawClipboardData)
        case nothing
        /// The pasteboard changed while its representations were read; reread on the next poll.
        case changedDuringRead
    }

    /// 快速提取原始数据（不计算哈希，避免阻塞主线程）
    /// 注意：检测顺序很重要！文件复制时剪贴板同时包含 file URL 和 plain text，
    /// 必须先检测 file URL，否则会被误识别为文本。
    func extractRawData(from pasteboard: NSPasteboard, changeCount: Int) async -> Extraction {
        let appBundleID = getFrontmostAppBundleID()
        // Representations are read over several IPC calls; content read while another copy
        // landed could mix two copies, so it is only accepted if the changeCount held.
        func verified(_ rawData: RawClipboardData) -> Extraction {
            pasteboard.changeCount == changeCount ? .content(rawData) : .changedDuringRead
        }

        // 检测顺序（默认）：File URLs > Image > RTF > HTML > Plain text
        // Plain text 必须放最后，因为其他类型通常也包含文本表示
        //
        // 例外：Office/Excel 复制单元格时，经常同时提供“图片预览 + HTML/RTF/文本”。
        // 此时如果优先选 Image，会导致历史记录变成图片，粘贴行为也不符合用户预期（表格应保持为富文本/文本）。
        //
        // 这里采用“仅在检测到明显的表格/Office 富文本信号时”才让 Image 退到后面，
        // 以避免影响浏览器/设计工具等真正的图片复制场景。

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let shouldPreferImageOverFileURLs = shouldPreferImageOverFileURLs(fileURLs: fileURLs, from: pasteboard)

        // 1. File URLs (最高优先级 - 文件复制总是带有文本表示)
        // 例外：部分 App（如 IM）复制图片时会同时给“临时图片文件路径 + 图片二进制”，这类场景应保留图片语义。
        if !fileURLs.isEmpty, !shouldPreferImageOverFileURLs {
            let paths = fileURLs.map { $0.path }.joined(separator: "\n")
            // 序列化文件 URL 以便后续恢复
            let urlData = Self.serializeFileURLs(fileURLs)
            return verified(RawClipboardData(
                type: .file,
                plainText: paths,
                rawData: urlData,
                appBundleID: appBundleID,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0)
            ))
        }

        let shouldPreferRichTypesOverImage = shouldPreferRichTypesOverImage(from: pasteboard)

        // 2. Image (PNG, TIFF, etc.) - 默认优先 PNG；TIFF 转 PNG 延迟到后台（避免主线程重编码）
        // v0.19: 图片统一使用 SHA256 去重（在后台线程计算），移除无用的轻量指纹
        if !shouldPreferRichTypesOverImage, let imageResult = extractImageDataForIngest(from: pasteboard, candidateFileURL: fileURLs.first) {
            let imageData = imageResult.data
            return verified(RawClipboardData(
                type: .image,
                plainText: "[Image]",
                rawData: imageData,
                appBundleID: appBundleID,
                sizeBytes: imageData.count,
                precomputedHash: nil,
                imageDataWasTIFF: imageResult.wasTIFF
            ))
        }

        // 3-5. RTF / HTML / plain text: read the representations here, process them off the main thread.
        // A 1 MB rich copy otherwise blocks the main thread for about two seconds.
        let rtfData = pasteboard.data(forType: .rtf)
        let htmlData = pasteboard.data(forType: .html)
        let string = pasteboard.string(forType: .string)
        guard pasteboard.changeCount == changeCount else { return .changedDuringRead }
        if rtfData != nil || htmlData != nil || string != nil {
            let parseHTMLOnMain: @MainActor @Sendable (Data) -> String? = { [self] data in
                extractPlainTextFromHTML(data)
            }
            let textRawData = await Task.detached(priority: .userInitiated) {
                await Self.makeTextRawData(
                    rtfData: rtfData,
                    htmlData: htmlData,
                    string: string,
                    appBundleID: appBundleID,
                    parseHTMLOnMain: parseHTMLOnMain
                )
            }.value
            if let textRawData {
                return .content(textRawData)
            }
        }

        // 6. Image（兜底）
        // 如果上面没有任何富文本/文本可用，再回退到图片，确保复制图表/截图等场景不丢失内容。
        // This read follows a suspension point, so confirm the pasteboard still holds this change.
        guard pasteboard.changeCount == changeCount else { return .changedDuringRead }
        if shouldPreferRichTypesOverImage, let imageResult = extractImageDataForIngest(from: pasteboard, candidateFileURL: fileURLs.first) {
            let imageData = imageResult.data
            return verified(RawClipboardData(
                type: .image,
                plainText: "[Image]",
                rawData: imageData,
                appBundleID: appBundleID,
                sizeBytes: imageData.count,
                precomputedHash: nil,
                imageDataWasTIFF: imageResult.wasTIFF
            ))
        }

        return .nothing
    }

    private func shouldPreferRichTypesOverImage(from pasteboard: NSPasteboard) -> Bool {
        // 仅当剪贴板确实包含图片时才需要此判断，避免无谓开销。
        guard let types = pasteboard.types, types.contains(.png) || types.contains(.tiff) else {
            return false
        }

        let hasHTML = types.contains(.html)
        let hasRTF = types.contains(.rtf)
        let hasString = types.contains(.string)
        guard hasHTML || hasRTF || hasString else { return false }

        // Office/Excel 复制通常会带一些自定义的 pasteboard types；优先用 types 快速识别。
        if types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("excel") }) {
            return true
        }

        if hasHTML, let htmlData = pasteboard.data(forType: .html), Self.htmlLooksLikeOfficeSpreadsheet(htmlData) {
            return true
        }

        if hasRTF, let rtfData = pasteboard.data(forType: .rtf), Self.rtfLooksLikeTable(rtfData) {
            return true
        }

        if hasString, let string = pasteboard.string(forType: .string), Self.stringLooksLikeTabularData(string) {
            return true
        }

        return false
    }

    private func shouldPreferImageOverFileURLs(fileURLs: [URL], from pasteboard: NSPasteboard) -> Bool {
        guard fileURLs.count == 1 else { return false }
        let fileURL = fileURLs[0]
        guard Self.isLikelyTemporaryImageFileURL(fileURL) else { return false }
        if extractImageDataForIngest(from: pasteboard, candidateFileURL: nil) != nil {
            return true
        }
        return Self.loadImageFileDataAsPNG(fileURL) != nil
    }

    private func getFrontmostAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 从剪贴板提取图片数据（用于 ingest），优先 PNG；TIFF 转 PNG 在后台执行
    private func extractImageDataForIngest(
        from pasteboard: NSPasteboard,
        candidateFileURL: URL? = nil
    ) -> (data: Data, wasTIFF: Bool)? {
        // Only read image representations the pasteboard declares; text copies skip them entirely.
        let types = pasteboard.types ?? []
        if types.contains(.png), let pngData = pasteboard.data(forType: .png) {
            return (pngData, false)
        }

        if types.contains(.tiff), let tiffData = pasteboard.data(forType: .tiff) {
            return (tiffData, true)
        }

        if NSImage.canInit(with: pasteboard),
           let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation,
           let pngData = Self.convertTIFFToPNG(tiffData) {
            return (pngData, false)
        }

        if let candidateFileURL,
           let pngData = Self.loadImageFileDataAsPNG(candidateFileURL) {
            return (pngData, false)
        }

        return nil
    }
}
