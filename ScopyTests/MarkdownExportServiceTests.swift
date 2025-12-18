import XCTest
import AppKit

@testable import Scopy

@MainActor
final class MarkdownExportServiceTests: XCTestCase {

    func testWritePNGToPasteboardWritesPNG() throws {
        // NOTE: We avoid exercising WKWebView snapshotting in unit tests because the tests run in an independent
        // bundle mode and WebKit snapshotting can fail without the hosted test runner / entitlements.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("Failed to create bitmap rep")
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 32)).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 8, y: 8, width: 48, height: 16)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to encode PNG")
            return
        }

        let pasteboardName = NSPasteboard.Name("ScopyTests.MarkdownExportServiceTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)

        try MarkdownExportService.writePNGToPasteboard(pngData: pngData, pasteboard: pasteboard)

        XCTAssertNotNil(pasteboard.data(forType: .png))
    }
}
