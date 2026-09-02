import AppKit
import XCTest

@testable import ScopyKit

@MainActor
final class MarkdownExportServiceTests: XCTestCase {

    func testWritePNGToPasteboardWritesPNG() throws {
        // NOTE: We avoid exercising WKWebView snapshotting in unit tests because the tests run in an independent
        // bundle mode and WebKit snapshotting can fail without the hosted test runner / entitlements.
        let pngData = try makePNGData()

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

    func testDeniedPasteboardAuthorizationPreservesEveryExistingRepresentation() throws {
        let pngData = try makePNGData()
        let pasteboardName = NSPasteboard.Name("ScopyTests.MarkdownExportServiceTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        let originalString = "preserve-text"
        let originalHTML = Data("<p>preserve-html</p>".utf8)
        pasteboard.clearContents()
        pasteboard.setString(originalString, forType: .string)
        pasteboard.setData(originalHTML, forType: .html)
        let changeCountBeforeWrite = pasteboard.changeCount

        let didWrite = try MarkdownExportService.writePNGToPasteboard(
            pngData: pngData,
            pasteboard: pasteboard,
            authorization: { false }
        )

        XCTAssertFalse(didWrite)
        XCTAssertEqual(pasteboard.changeCount, changeCountBeforeWrite)
        XCTAssertEqual(pasteboard.string(forType: .string), originalString)
        XCTAssertEqual(pasteboard.data(forType: .html), originalHTML)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testChangedPasteboardDeniesCommitWritesOnlyErrorDumpAndPreservesNewerCopy() throws {
        let pngData = try makePNGData()
        let pasteboardName = NSPasteboard.Name("ScopyTests.MarkdownExportLease.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        pasteboard.setString("before-export", forType: .string)
        let lease = MarkdownExportService.PasteboardWriteLease(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("newer-user-copy", forType: .string)
        pasteboard.setData(Data("<p>newer</p>".utf8), forType: .html)
        let newerChangeCount = pasteboard.changeCount

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-export-commit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dumpURL = directory.appendingPathComponent("success.png")
        let errorURL = directory.appendingPathComponent("error.txt")
        let outcome = MarkdownExportService.ExportOutcome(
            pngData: pngData,
            stats: MarkdownExportService.ExportStats(finalPNGBytes: pngData.count, pngquantApplied: false)
        )

        let result = MarkdownExportService.commitRenderedExport(
            outcome,
            pasteboard: pasteboard,
            lease: lease,
            authorizePasteboardWrite: { true },
            dumpURL: dumpURL,
            errorDumpURL: errorURL
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected changed pasteboard to reject commit")
        }
        XCTAssertTrue(error is MarkdownExportService.ExportError)
        XCTAssertEqual(pasteboard.changeCount, newerChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer-user-copy")
        XCTAssertEqual(pasteboard.data(forType: .html), Data("<p>newer</p>".utf8))
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dumpURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: errorURL.path))
    }

    func testPasteboardEncodingFailureDoesNotCreateSuccessDumpOrClearClipboard() throws {
        let pasteboardName = NSPasteboard.Name("ScopyTests.MarkdownExportFailure.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        pasteboard.setString("keep-me", forType: .string)
        let lease = MarkdownExportService.PasteboardWriteLease(pasteboard: pasteboard)
        let changeCount = pasteboard.changeCount

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-export-failure-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dumpURL = directory.appendingPathComponent("success.png")
        let errorURL = directory.appendingPathComponent("error.txt")
        let invalidPNG = Data("not-a-png".utf8)
        let outcome = MarkdownExportService.ExportOutcome(
            pngData: invalidPNG,
            stats: MarkdownExportService.ExportStats(finalPNGBytes: invalidPNG.count, pngquantApplied: false)
        )

        let result = MarkdownExportService.commitRenderedExport(
            outcome,
            pasteboard: pasteboard,
            lease: lease,
            authorizePasteboardWrite: { true },
            dumpURL: dumpURL,
            errorDumpURL: errorURL
        )

        guard case .failure = result else {
            return XCTFail("Expected invalid image payload to fail")
        }
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep-me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dumpURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: errorURL.path))
    }

    func testMarkdownExportConcurrencyGateBoundsActiveAndPendingWork() {
        let gate = MarkdownExportConcurrencyGate(limit: 2, maximumPendingCount: 1)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let rejected = UUID()
        var started: [UUID] = []

        XCTAssertEqual(gate.submit(id: first) { started.append(first) }, .started)
        XCTAssertEqual(gate.submit(id: second) { started.append(second) }, .started)
        XCTAssertEqual(gate.submit(id: third) { started.append(third) }, .queued)
        XCTAssertEqual(gate.submit(id: rejected) { started.append(rejected) }, .rejected)
        XCTAssertEqual(gate.activeCount, 2)
        XCTAssertEqual(gate.pendingCount, 1)
        XCTAssertEqual(started, [first, second])

        gate.finish(id: first)
        XCTAssertEqual(gate.activeCount, 2)
        XCTAssertEqual(gate.pendingCount, 0)
        XCTAssertEqual(started, [first, second, third])
        XCTAssertFalse(gate.activeIDs.contains(first))
        XCTAssertTrue(gate.activeIDs.contains(third))
    }

    func testMarkdownExportCancellationHandleRunsCancellationOnlyOnce() {
        var cancellationCount = 0
        let handle = MarkdownExportService.CancellationHandle {
            cancellationCount += 1
        }

        handle.cancel()
        handle.cancel()

        XCTAssertEqual(cancellationCount, 1)
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
        XCTAssertFalse(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 14_400))
        XCTAssertTrue(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 14_401))
        XCTAssertTrue(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 29_001))
    }

    private func loadRealPalettedFixturePNGData() throws -> Data {
        try TestFixture.data("history-replay-real-screenshot-paletted.png")
    }

    private func makePNGData() throws -> Data {
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
            throw NSError(
                domain: "MarkdownExportServiceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"]
            )
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 32)).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 8, y: 8, width: 48, height: 16)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "MarkdownExportServiceTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"]
            )
        }
        return pngData
    }
}
