import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File extension for stored image bytes, decided by content rather than by the capture path:
/// a TIFF whose PNG conversion failed must not be written as `.png`.
enum ImageFileExtension {
    static let unrecognized = "dat"

    static func sniff(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return unrecognized }
        return fileExtension(of: source)
    }

    static func sniff(fileAt url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return unrecognized }
        return fileExtension(of: source)
    }

    private static func fileExtension(of source: CGImageSource) -> String {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let fileExtension = UTType(identifier)?.preferredFilenameExtension else {
            return unrecognized
        }
        return fileExtension
    }
}
