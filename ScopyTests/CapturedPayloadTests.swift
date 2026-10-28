import XCTest
@testable import ScopyKit

private actor FileTransformGate {
    private var paths: (input: URL, output: URL)?
    private var arrival: CheckedContinuation<(input: URL, output: URL), Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause(input: URL, output: URL) async {
        paths = (input, output)
        arrival?.resume(returning: (input, output))
        arrival = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async -> (input: URL, output: URL) {
        if let paths { return paths }
        return await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class CapturedPayloadTests: XCTestCase {
    func testOriginalFilePlacementRetainsReplaySourceAndIdentity() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(repeating: 0x31, count: ScopyThresholds.ingestSpoolBytes + 1)
        let content = try await makeContent(bytes, in: directory)
        let ingest = try XCTUnwrap(content.payload.ingest)
        guard case .file(let file) = content.payload.storage else {
            return XCTFail("Large original payload must remain file-backed")
        }
        XCTAssertEqual(file.url, ingest.payloadURL)
        XCTAssertEqual(content.contentHash, ClipboardMonitor.computeHashStatic(bytes))

        let destination = directory.appendingPathComponent("stored-original")
        try file.copyOrMove(to: destination.path)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: ingest.payloadURL), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingest.envelopeURL.path))
    }

    func testFileListSpoolingUsesCombinedCaptureSize() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = (0..<600).map { "/tmp/\($0)-" + String(repeating: "x", count: 96) }
        let plainText = paths.joined(separator: "\n")
        let bytes = try XCTUnwrap(CapturePolicy.serializeFileURLs(paths.map { URL(fileURLWithPath: $0) }))
        let sizeBytes = plainText.utf8.count + bytes.count
        XCTAssertLessThan(bytes.count, ScopyThresholds.ingestSpoolBytes)
        XCTAssertGreaterThan(sizeBytes, ScopyThresholds.ingestSpoolBytes)
        let content = try await makeContent(
            bytes, in: directory, type: .file, plainText: plainText, sizeBytes: sizeBytes
        )
        guard case .file(let file) = content.payload.storage else {
            return XCTFail("File-list paths and serialized URLs jointly determine spooling")
        }
        XCTAssertEqual(content.sizeBytes, sizeBytes)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(content.contentHash, "file:" + ClipboardMonitor.computeHashStatic(Data(plainText.utf8)))
    }

    func testPreparedFileLivesThroughCopiesAndReleasesWithoutAcknowledgingSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(repeating: 0x41, count: ScopyThresholds.ingestSpoolBytes + 1)
        let content = try await makeContent(original, in: directory)
        let ingest = try XCTUnwrap(content.payload.ingest)
        let replacement = Data(repeating: 0x42, count: ScopyThresholds.ingestSpoolBytes + 2)
        var first: CapturedPayload? = content.payload.replacingData(replacement, type: .html)
        var retained = first
        let workURL = try fileURL(try XCTUnwrap(first))
        XCTAssertNotEqual(workURL, ingest.payloadURL)
        XCTAssertEqual(first?.ingest?.id, ingest.id)
        XCTAssertEqual(first?.ingest?.envelopeURL, ingest.envelopeURL)

        first = nil
        XCTAssertEqual(try Data(contentsOf: workURL), replacement)
        withExtendedLifetime(retained) {}
        retained = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: workURL.path))
        XCTAssertEqual(try Data(contentsOf: ingest.payloadURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingest.envelopeURL.path))
    }

    func testPreparedFilePlacementSurvivesPayloadRelease() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = try await makeContent(
            Data(repeating: 0x51, count: ScopyThresholds.ingestSpoolBytes + 1), in: directory
        )
        let replacement = Data(repeating: 0x52, count: ScopyThresholds.ingestSpoolBytes + 1)
        let destination = directory.appendingPathComponent("stored-prepared")
        let workURL = try placeReplacement(
            content.payload, bytes: replacement, at: destination
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: workURL.path))
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(content.payload.ingest).payloadURL.path))
    }

    func testFileTransformPublishesReadBackBytesWithoutModifyingSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(repeating: 0x61, count: ScopyThresholds.ingestSpoolBytes + 1)
        let content = try await makeContent(original, in: directory)
        let ingest = try XCTUnwrap(content.payload.ingest)
        let transformed = Data([0x01, 0x02])
        var result = try await content.payload.transformingFile { input, output in
            XCTAssertEqual(try Data(contentsOf: input), original)
            try transformed.write(to: output)
            return true
        }
        XCTAssertEqual(result?.data, transformed)
        XCTAssertEqual(result?.payload.ingest?.id, ingest.id)
        let output = try fileURL(try XCTUnwrap(result?.payload))
        XCTAssertEqual(try Data(contentsOf: output), transformed)
        result = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: ingest.payloadURL), original)
    }

    func testCancelledTransformOwnsBothWorkFilesUntilTheOperationReturns() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(repeating: 0x71, count: ScopyThresholds.ingestSpoolBytes + 1)
        let content = try await makeContent(original, in: directory)
        let ingest = try XCTUnwrap(content.payload.ingest)
        let gate = FileTransformGate()
        let transformation = Task {
            try await content.payload.replacingData(original, type: .image).transformingFile { input, output in
                try Data([0x01]).write(to: output)
                await gate.pause(input: input, output: output)
                try Task.checkCancellation()
                return true
            }
        }
        let paths = await gate.waitUntilPaused()
        transformation.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.input.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.output.path))
        await gate.release()
        do {
            _ = try await transformation.value
            XCTFail("Cancelled preparation must not publish its output")
        } catch is CancellationError {
            // The pending envelope remains the authority after a cancelled preparation.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.input.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.output.path))
        XCTAssertEqual(try Data(contentsOf: ingest.payloadURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingest.envelopeURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(IngestSpool.transientWorkPrefix) })
    }

    func testFileTransformRejectsSubstitutedSourceAndOutput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data(repeating: 0x61, count: ScopyThresholds.ingestSpoolBytes + 1)
        let content = try await makeContent(original, in: directory)
        let ingest = try XCTUnwrap(content.payload.ingest)
        let outside = directory.appendingPathComponent("unowned-by-spool")
        try original.write(to: outside)
        do {
            _ = try await content.payload.transformingFile { _, output in
                try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)
                return true
            }
            XCTFail("A transform cannot publish a symbolic link")
        } catch IngestSpool.ReadError.unsafeArtifact {
            // A transform's output must be an owned regular file before it is read.
        }
        try FileManager.default.removeItem(at: ingest.payloadURL)
        try FileManager.default.createSymbolicLink(at: ingest.payloadURL, withDestinationURL: outside)
        do {
            _ = try await content.payload.transformingFile { _, _ in
                XCTFail("A substituted source must be rejected before invoking a transform")
                return true
            }
            XCTFail("A source cannot be a symbolic link")
        } catch IngestSpool.ReadError.unsafeArtifact {
            // The outside target is not owned by the capture.
        }
        guard case .file(let source) = content.payload.storage else {
            return XCTFail("Large original payload must remain file-backed")
        }
        let destination = directory.appendingPathComponent("must-not-be-published")
        XCTAssertThrowsError(try source.copyOrMove(to: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(IngestSpool.transientWorkPrefix) })
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-captured-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContent(
        _ bytes: Data,
        in directory: URL,
        type: ClipboardItemType = .image,
        plainText: String = "captured",
        sizeBytes: Int? = nil
    ) async throws -> ClipboardMonitor.ClipboardContent {
        let envelopeURL = try IngestSpool.persistPendingEnvelope(
            for: ClipboardMonitor.RawClipboardData(
                type: type, plainText: plainText, rawData: bytes,
                appBundleID: nil, sizeBytes: sizeBytes ?? bytes.count
            ),
            in: directory
        )
        let outcome = await IngestEnvelopeProcessor.buildContent(
            from: envelopeURL, ingestDirectory: directory, delay: .zero
        )
        guard case .content(let content) = outcome else {
            XCTFail("A persisted valid envelope must produce content")
            throw CocoaError(.fileReadUnknown)
        }
        return content
    }

    private func fileURL(_ payload: CapturedPayload) throws -> URL {
        guard case .file(let file) = payload.storage else {
            throw CocoaError(.fileReadUnknown)
        }
        return file.url
    }

    private func placeReplacement(_ payload: CapturedPayload, bytes: Data, at destination: URL) throws -> URL {
        let prepared = payload.replacingData(bytes, type: .html)
        guard case .file(let file) = prepared.storage else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.copyOrMove(to: destination.path)
        return file.url
    }
}
