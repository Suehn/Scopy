import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScopyKit

@MainActor
final class ThumbnailPipelineTests: XCTestCase {
    func testMakeThumbnailPNGFromFilePathDownsamplesToMaxHeight() throws {
        let url = try writeTestPNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let maxHeight = 120
        guard let pngData = StorageService.makeThumbnailPNG(fromFileAtPath: url.path, maxHeight: maxHeight) else {
            XCTFail("Expected PNG thumbnail data")
            return
        }

        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            XCTFail("Expected CGImageSource from thumbnail PNG data")
            return
        }

        let type = CGImageSourceGetType(source) as String?
        XCTAssertEqual(type, UTType.png.identifier)

        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        XCTAssertNotNil(cgImage)
        if let cgImage {
            XCTAssertLessThanOrEqual(abs(cgImage.height - maxHeight), 1)
        }
    }

    func testThumbnailCacheRemoveEvictsCachedImage() async throws {
        let url = try writeTestPNG(width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: url) }

        let path = url.path
        ThumbnailCache.shared.clear()
        XCTAssertNil(ThumbnailCache.shared.cachedImage(path: path))

        let loaded = await ThumbnailCache.shared.loadImage(path: path, priority: .userInitiated)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(ThumbnailCache.shared.cachedImage(path: path))

        ThumbnailCache.shared.remove(path: path)
        XCTAssertNil(ThumbnailCache.shared.cachedImage(path: path))
    }

    private func writeTestPNG(width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 1)
        }

        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 2)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-test-\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 3)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 4)
        }

        return url
    }
}
