import AppKit
import Foundation

/// One pasteboard change, read on the main actor over several IPC calls. Content is accepted
/// only if the changeCount held for the whole read, so two overlapping copies never mix.
/// Nothing is hashed here: small text is hashed inline by the monitor, images and large
/// payloads in envelope processing off the main actor.
@MainActor
struct PasteboardReadSession {
    let pasteboard: NSPasteboard
    let changeCount: Int

    enum Outcome {
        case content(ClipboardMonitor.RawClipboardData)
        case nothing
        /// The pasteboard changed while its representations were read; reread on the next poll.
        case changedDuringRead
    }

    /// Detection order matters: a copied file carries both a file URL and its path as plain
    /// text, so file URLs are checked first.
    func read() async -> Outcome {
        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        func verified(_ rawData: ClipboardMonitor.RawClipboardData) -> Outcome {
            pasteboard.changeCount == changeCount ? .content(rawData) : .changedDuringRead
        }

        // Default order: file URLs > image > RTF > HTML > plain text. Plain text goes last
        // because the other types usually carry a text representation too.
        //
        // Exception: copied Office/Excel cells offer an image preview next to HTML/RTF/text.
        // Preferring the image would store a picture of the table and paste as one, so the
        // image is demoted only when clear table/Office signals are present; browser and
        // design-tool image copies keep the default order.

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let shouldPreferImageOverFileURLs = shouldPreferImageOverFileURLs(fileURLs)

        // 1. File URLs. Exception: some apps (messaging clients) copy an image as a temporary
        // image file plus the bitmap; that stays an image.
        if !fileURLs.isEmpty, !shouldPreferImageOverFileURLs {
            let paths = fileURLs.map { $0.path }.joined(separator: "\n")
            let urlData = CapturePolicy.serializeFileURLs(fileURLs)
            return verified(ClipboardMonitor.RawClipboardData(
                type: .file,
                plainText: paths,
                rawData: urlData,
                appBundleID: appBundleID,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0)
            ))
        }

        let shouldPreferRichTypesOverImage = shouldPreferRichTypesOverImage()

        // 2. Image. PNG is preferred; declared TIFF bytes are kept as read and re-encoded in
        // envelope processing off the main actor. Images deduplicate by SHA-256 of the bytes.
        if !shouldPreferRichTypesOverImage, let imageResult = imageDataForIngest(candidateFileURL: fileURLs.first) {
            let imageData = imageResult.data
            return verified(ClipboardMonitor.RawClipboardData(
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
            let parseHTMLOnMain: @MainActor @Sendable (Data) -> String? = { data in
                CapturedTextExtraction.extractPlainTextFromHTML(data)
            }
            let textRawData = await Task.detached(priority: .userInitiated) {
                await CapturedTextExtraction.makeTextRawData(
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

        // 6. Image fallback for a demoted image whose rich/text representations produced
        // nothing, so charts and screenshots copied with table signals are not lost.
        // This read follows a suspension point, so confirm the pasteboard still holds this change.
        guard pasteboard.changeCount == changeCount else { return .changedDuringRead }
        if shouldPreferRichTypesOverImage, let imageResult = imageDataForIngest(candidateFileURL: fileURLs.first) {
            let imageData = imageResult.data
            return verified(ClipboardMonitor.RawClipboardData(
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

    private func shouldPreferRichTypesOverImage() -> Bool {
        // Only relevant when an image representation is declared.
        guard let types = pasteboard.types, types.contains(.png) || types.contains(.tiff) else {
            return false
        }

        let hasHTML = types.contains(.html)
        let hasRTF = types.contains(.rtf)
        let hasString = types.contains(.string)
        guard hasHTML || hasRTF || hasString else { return false }

        // Office/Excel copies declare custom pasteboard types; checking them avoids reading data.
        if types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("excel") }) {
            return true
        }

        if hasHTML, let htmlData = pasteboard.data(forType: .html), CapturePolicy.htmlLooksLikeOfficeSpreadsheet(htmlData) {
            return true
        }

        if hasRTF, let rtfData = pasteboard.data(forType: .rtf), CapturePolicy.rtfLooksLikeTable(rtfData) {
            return true
        }

        if hasString, let string = pasteboard.string(forType: .string), CapturePolicy.stringLooksLikeTabularData(string) {
            return true
        }

        return false
    }

    private func shouldPreferImageOverFileURLs(_ fileURLs: [URL]) -> Bool {
        guard fileURLs.count == 1 else { return false }
        let fileURL = fileURLs[0]
        guard CapturePolicy.isLikelyTemporaryImageFileURL(fileURL) else { return false }
        if imageDataForIngest(candidateFileURL: nil) != nil {
            return true
        }
        return ClipboardMonitor.loadImageFileDataAsPNG(fileURL) != nil
    }

    /// Image bytes for ingest. Declared PNG or TIFF bytes are returned as read (TIFF is
    /// re-encoded later off the main actor); the NSImage and file-URL fallbacks re-encode here.
    private func imageDataForIngest(candidateFileURL: URL?) -> (data: Data, wasTIFF: Bool)? {
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
           let pngData = ClipboardMonitor.convertTIFFToPNG(tiffData) {
            return (pngData, false)
        }

        if let candidateFileURL,
           let pngData = ClipboardMonitor.loadImageFileDataAsPNG(candidateFileURL) {
            return (pngData, false)
        }

        return nil
    }
}
