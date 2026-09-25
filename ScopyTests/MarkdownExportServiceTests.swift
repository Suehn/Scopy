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

    func testDebugBypassesPDFForVeryTallContent() {
        XCTAssertFalse(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 14_400))
        XCTAssertTrue(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 14_401))
        XCTAssertTrue(MarkdownExportService.debugShouldBypassPDFForVeryTallContent(heightPoints: 29_001))
    }

    func testLateLayoutMessageFromPreviousPhaseIsIgnored() throws {
        func message(phase: Int, event: String) throws -> ExportLayoutMessage {
            try XCTUnwrap(ExportLayoutMessage(body: [
                "phase": phase, "event": event, "frames": 12, "stableFrames": 3, "height": 480, "live": 480,
                "fonts": "loaded", "renderReady": true, "renderFailed": false, "renderErrorReason": ""
            ] as [String: Any]))
        }
        var phases = ExportLayoutPhases()
        _ = phases.begin()
        let current = phases.begin()

        XCTAssertFalse(phases.receive(try message(phase: current - 1, event: "settled")))
        XCTAssertNil(phases.latest, "a settle from the previous wait must not satisfy the current one")
        XCTAssertTrue(phases.receive(try message(phase: current, event: "settled")))
        XCTAssertEqual(phases.latest?.sample.height, 480)
    }

    /// The host panel is ordered out once the document is ready, so animation frames stop and no settle is pushed;
    /// the export must still finish through the time-based fallback.
    func testOccludedExportFallsBackToTimeBasedSettle() async throws {
        let assets = try LiveMarkdownDocument()
        defer { assets.close() }
        ExportCoordinator.markdownPreviewResourceURLForTesting = assets.assetRoot
        ExportCoordinator.ordersOutHostWindowForTesting = true
        defer {
            ExportCoordinator.markdownPreviewResourceURLForTesting = nil
            ExportCoordinator.ordersOutHostWindowForTesting = false
        }
        let html = MarkdownHTMLDocumentBuilder.document(source: "# Occluded export\n\nThe host panel leaves the screen after the document is ready.")

        let result = await withCheckedContinuation { continuation in
            MarkdownExportService.exportToPNGData(html: html) { continuation.resume(returning: $0) }
        }
        try Self.skipIfTheHostCannotRunTheRendererBundle(result)

        let png = try result.get().pngData
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Cancelling an export stops its encoding (pngquant is terminated) and hands the concurrency slot back only after
    /// that work has exited, so cancel-and-retry cannot exceed the two concurrent exports.
    func testCancelledExportReleasesItsSlotOnlyAfterEncodingWorkExits() async throws {
        let assets = try LiveMarkdownDocument()
        defer { assets.close() }
        ExportCoordinator.markdownPreviewResourceURLForTesting = assets.assetRoot
        defer { ExportCoordinator.markdownPreviewResourceURLForTesting = nil }
        let started = assets.assetRoot.appendingPathComponent("pngquant-started")
        let slowPngquant = assets.assetRoot.appendingPathComponent("slow-pngquant")
        try "#!/bin/sh\ntouch '\(started.path)'\nsleep 30\n".write(to: slowPngquant, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowPngquant.path)
        let options = PngquantService.Options(binaryPath: slowPngquant.path, qualityMin: 60, qualityMax: 80, speed: 4, colors: 256)
        let gate = ExportCoordinator.concurrencyGate
        let idleCount = gate.activeCount
        var result: Result<MarkdownExportService.ExportOutcome, Error>?

        let handle = MarkdownExportService.exportToPNGData(
            html: MarkdownHTMLDocumentBuilder.document(source: "# Slow encoder\n\nBody"),
            pngquantOptions: options
        ) { result = $0 }
        try await waitUntil(timeout: 20) { FileManager.default.fileExists(atPath: started.path) || result != nil }
        if let result { try Self.skipIfTheHostCannotRunTheRendererBundle(result) }
        handle.cancel()

        guard case .failure(let error) = result else { return XCTFail("cancel must complete the export") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(gate.activeCount, idleCount + 1, "the slot stays taken while pngquant is being stopped")
        try await waitUntil(timeout: 3) { gate.activeCount == idleCount }
    }

    /// The export document references the renderer bundle as a file subresource of a string-loaded document. A
    /// WebContent process without read access to the temporary asset copy (the macos-15 CI image) never runs the
    /// bundle and the first script call fails on `window.ScopyDocument`; that host is environment-blocked for the
    /// live export tests, which need the app bundle there.
    private static func skipIfTheHostCannotRunTheRendererBundle(_ result: Result<MarkdownExportService.ExportOutcome, Error>) throws {
        guard case .failure(let error) = result, String(describing: error).contains("window.ScopyDocument") else { return }
        throw XCTSkip("this host cannot load the renderer bundle for a string-loaded export document: \(error)")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met within \(timeout) s") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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
