import AppKit
import XCTest

@testable import ScopyKit

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
        pasteboard.clearContents()
        pasteboard.setString("stale-text", forType: .string)
        pasteboard.setData(Data("<p>stale-html</p>".utf8), forType: .html)

        try MarkdownExportService.writePNGToPasteboard(pngData: pngData, pasteboard: pasteboard)

        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(pasteboard.data(forType: .html))
    }

    func testWritePNGToPasteboardPreservesPalettedPrimaryPNGBytes() throws {
        let pngData = try loadRealPalettedFixturePNGData()

        let pasteboardName = NSPasteboard.Name("ScopyTests.MarkdownExportServiceTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        try MarkdownExportService.writePNGToPasteboard(pngData: pngData, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testDebugMaxSupportedHeightPixelsIsTenTimesPreviousBudgetAtDefaultWidth() {
        let width = MarkdownExportService.defaultTargetWidthPixels
        let previousTotalPixels: CGFloat = 60_000_000
        let expectedBudget = floor((previousTotalPixels * 10) / width)
        let currentBudget = MarkdownExportService.debugMaxSupportedHeightPixels(targetWidthPixels: width)

        XCTAssertEqual(currentBudget, expectedBudget, accuracy: 0.5)
    }

    func testDebugUsesFileBackedBitmapOnceExportExceedsPreviousInMemoryBudget() {
        let width = Int(MarkdownExportService.defaultTargetWidthPixels)
        let previousMaxInMemoryHeight = Int(floor(60_000_000 / CGFloat(width)))

        XCTAssertFalse(
            MarkdownExportService.debugUsesFileBackedBitmap(
                widthPixels: width,
                heightPixels: previousMaxInMemoryHeight
            )
        )
        XCTAssertTrue(
            MarkdownExportService.debugUsesFileBackedBitmap(
                widthPixels: width,
                heightPixels: previousMaxInMemoryHeight + 1
            )
        )
    }

    func testDebugBypassesPDFForVeryTallContent() {
        XCTAssertFalse(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 29_000))
        XCTAssertTrue(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 29_001))
    }

    private func loadRealPalettedFixturePNGData() throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/history-replay-real-screenshot-paletted.png")
        return try Data(contentsOf: fixtureURL, options: [.mappedIfSafe])
    }
}
