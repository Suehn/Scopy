import AppKit
import Foundation

/// Owns the representations of one pasteboard change. Type decisions and text extraction use
/// the same reads, including missing data. The changeCount must hold across all pasteboard
/// reads, so overlapping copies never mix; processing the owned bytes may finish later.
@MainActor
final class PasteboardReadSession {
    private let pasteboard: NSPasteboard
    private let changeCount: Int
    private let types: Set<NSPasteboard.PasteboardType>

    private lazy var rtfData = types.contains(.rtf) ? pasteboard.data(forType: .rtf) : nil
    private lazy var htmlData = types.contains(.html) ? pasteboard.data(forType: .html) : nil
    private lazy var string = types.contains(.string) ? pasteboard.string(forType: .string) : nil

    init(pasteboard: NSPasteboard, changeCount: Int) {
        self.pasteboard = pasteboard
        self.changeCount = changeCount
        self.types = Set(pasteboard.types ?? [])
    }

    enum Outcome {
        case content(ClipboardMonitor.RawClipboardData)
        case nothing
        /// The pasteboard changed while its representations were read; reread on the next poll.
        case changedDuringRead
    }

    /// Detection order matters: a copied file carries both a file URL and its path as plain
    /// text, so file URLs are checked first.
    func read() async -> Outcome {
        // Clearing and filling a pasteboard can share one change count. An empty type
        // snapshot cannot settle that count before its representations arrive.
        guard !types.isEmpty else { return .changedDuringRead }
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

        // 1. File URLs. Exception: some apps (messaging clients) copy an image as a temporary
        // image file plus the bitmap; that stays an image. Resolve it once, taking ownership
        // of the bytes before any temporary file can be handed to the ingest queue.
        var imageResult: (data: Data, wasTIFF: Bool)?
        if !fileURLs.isEmpty {
            if fileURLs.count == 1, CapturePolicy.isLikelyTemporaryImageFileURL(fileURLs[0]) {
                imageResult = await imageDataForIngest(candidateFileURL: fileURLs[0])
                guard pasteboard.changeCount == changeCount else { return .changedDuringRead }
            }
            if imageResult == nil {
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
        }

        let shouldPreferRichTypesOverImage = shouldPreferRichTypesOverImage()

        // 2. Image. PNG is preferred; declared TIFF bytes are kept as read and re-encoded in
        // envelope processing off the main actor. Images deduplicate by SHA-256 of the bytes.
        if !shouldPreferRichTypesOverImage {
            if imageResult == nil {
                imageResult = await imageDataForIngest(candidateFileURL: fileURLs.first)
            }
            if let imageResult {
                return verified(imageCapture(imageResult, appBundleID: appBundleID))
            }
            guard pasteboard.changeCount == changeCount else { return .changedDuringRead }
        }

        // 3-5. RTF / HTML / plain text: read the representations here, process them off the main thread.
        // A 1 MB rich copy otherwise blocks the main thread for about two seconds.
        let rtfData = self.rtfData
        let htmlData = self.htmlData
        let string = self.string
        guard pasteboard.changeCount == changeCount else { return .changedDuringRead }
        if rtfData != nil || htmlData != nil || string != nil {
            let textRawData = await Task.detached(priority: .userInitiated) {
                await CapturedTextExtraction.makeTextRawData(
                    rtfData: rtfData,
                    htmlData: htmlData,
                    string: string,
                    appBundleID: appBundleID
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
        if shouldPreferRichTypesOverImage {
            if imageResult == nil {
                imageResult = await imageDataForIngest(candidateFileURL: fileURLs.first)
            }
            if let imageResult {
                return verified(imageCapture(imageResult, appBundleID: appBundleID))
            }
        }

        return pasteboard.changeCount == changeCount ? .nothing : .changedDuringRead
    }

    private func imageCapture(
        _ image: (data: Data, wasTIFF: Bool),
        appBundleID: String?
    ) -> ClipboardMonitor.RawClipboardData {
        ClipboardMonitor.RawClipboardData(
            type: .image,
            plainText: "[Image]",
            rawData: image.data,
            appBundleID: appBundleID,
            sizeBytes: image.data.count,
            imageDataWasTIFF: image.wasTIFF
        )
    }

    private func shouldPreferRichTypesOverImage() -> Bool {
        // Only relevant when an image representation is declared.
        guard types.contains(.png) || types.contains(.tiff) else {
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

        if hasHTML, let htmlData, CapturePolicy.htmlLooksLikeOfficeSpreadsheet(htmlData) {
            return true
        }

        if hasRTF, let rtfData, CapturePolicy.rtfLooksLikeTable(rtfData) {
            return true
        }

        if hasString, let string, CapturePolicy.stringLooksLikeTabularData(string) {
            return true
        }

        return false
    }

    /// Image bytes for ingest. Declared PNG or TIFF bytes are returned as read (TIFF is
    /// re-encoded in ingest). AppKit alone reads the fallback representation on the main actor;
    /// its PNG encoding and temporary-file reads finish off the main actor before returning.
    private func imageDataForIngest(candidateFileURL: URL?) async -> (data: Data, wasTIFF: Bool)? {
        // Only read image representations the pasteboard declares; text copies skip them entirely.
        if types.contains(.png), let pngData = pasteboard.data(forType: .png) {
            return (pngData, false)
        }

        if types.contains(.tiff), let tiffData = pasteboard.data(forType: .tiff) {
            return (tiffData, true)
        }

        if NSImage.canInit(with: pasteboard),
           let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation {
            let pngData = await Task.detached(priority: .userInitiated) {
                ClipboardMonitor.convertTIFFToPNG(tiffData)
            }.value
            if let pngData {
                return (pngData, false)
            }
        }

        if let candidateFileURL {
            let pngData = await Task.detached(priority: .userInitiated) {
                ClipboardMonitor.loadImageFileDataAsPNG(candidateFileURL)
            }.value
            if let pngData {
                return (pngData, false)
            }
        }

        return nil
    }
}
