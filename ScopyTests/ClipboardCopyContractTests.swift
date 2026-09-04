import AppKit
import XCTest
@testable import ScopyKit

/// The contract that makes "copy succeeded" observable to the caller.
///
/// A failed pasteboard write leaves the previous clipboard content in place. If copy reports
/// success anyway, the panel closes over an unchanged clipboard and the Codex path pastes the
/// *previous* content into the frontmost app, so failure has to be an error, usage stats must not
/// advance, and the pasteboard must be left exactly as it was.
@MainActor
final class ClipboardCopyContractTests: XCTestCase {
    private var service: (any ClipboardServiceProtocol)!
    private var storage: StorageService!
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!
    private var settingsSuiteName: String?
    private var baseURL: URL!
    private var databasePath: String!

    override func setUp() async throws {
        let suiteName = "scopy-copy-contract-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settingsSuiteName = suiteName
        settingsStore = SettingsStore(suiteName: suiteName)

        pasteboard = NSPasteboard.withUniqueName()

        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-copy-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        databasePath = baseURL.appendingPathComponent("clipboard.db").path
    }

    override func tearDown() async throws {
        if let service {
            await service.stopAndWait()
        }
        service = nil
        storage = nil
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
        baseURL = nil
        databasePath = nil
        pasteboard = nil
        settingsStore = nil
        if let suiteName = settingsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        settingsSuiteName = nil
    }

    // MARK: - Failure reporting

    func testCopyToClipboardThrowsItemNotFoundForUnknownID() async throws {
        try await startService(seed: { _ in })
        writeBaselineClipboard()

        let missingID = UUID()
        await assertThrowsCopyError(.itemNotFound(missingID)) {
            try await self.service.copyToClipboard(itemID: missingID)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "baseline")
    }

    func testCopyToClipboardThrowsWhenExternalPayloadIsGoneAndLeavesClipboardAndUsageUntouched() async throws {
        var itemID = UUID()
        try await startService(seed: { storage in
            let payload = Data(repeating: 0xAB, count: ScopyThresholds.externalStorageBytes)
            let item = try await storage.upsertItem(
                ClipboardMonitor.ClipboardContent(
                    type: .html,
                    plainText: "external payload",
                    payload: .data(payload),
                    appBundleID: "com.test.app",
                    contentHash: UUID().uuidString,
                    sizeBytes: payload.count
                )
            )
            itemID = item.id
            // The row survives; only its external file is lost.
            let storageRef = try XCTUnwrap(item.storageRef)
            try FileManager.default.removeItem(atPath: storageRef)
        })
        writeBaselineClipboard()

        let useCountBefore = try await useCount(of: itemID)
        await assertThrowsCopyError(.payloadUnavailable(itemID)) {
            try await self.service.copyToClipboard(itemID: itemID)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "baseline")
        XCTAssertNil(pasteboard.data(forType: .html))
        let useCountAfter = try await useCount(of: itemID)
        XCTAssertEqual(useCountAfter, useCountBefore, "A copy that never reached the pasteboard must not count as a use")
    }

    func testCodexOptimizedCopyThrowsWhenExternalImagePayloadIsGone() async throws {
        var itemID = UUID()
        try await startService(seed: { storage in
            let payload = Data(repeating: 0x7F, count: ScopyThresholds.externalStorageBytes)
            let item = try await storage.upsertItem(
                ClipboardMonitor.ClipboardContent(
                    type: .image,
                    plainText: "[Image]",
                    payload: .data(payload),
                    appBundleID: "com.test.app",
                    contentHash: UUID().uuidString,
                    sizeBytes: payload.count
                )
            )
            itemID = item.id
            let storageRef = try XCTUnwrap(item.storageRef)
            try FileManager.default.removeItem(atPath: storageRef)
        })
        writeBaselineClipboard()

        await assertThrowsCopyError(.payloadUnavailable(itemID)) {
            try await self.service.copyToClipboardOptimizedForCodex(itemID: itemID)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "baseline")
    }

    func testCopyToClipboardThrowsWhenStoredImageBytesAreNotRenderable() async throws {
        var itemID = UUID()
        try await startService(seed: { storage in
            let item = try await storage.upsertItem(
                ClipboardMonitor.ClipboardContent(
                    type: .image,
                    plainText: "[Image]",
                    payload: .data(Data([0x00, 0x01, 0x02, 0x03])),
                    appBundleID: "com.test.app",
                    contentHash: UUID().uuidString,
                    sizeBytes: 4
                )
            )
            itemID = item.id
        })
        writeBaselineClipboard()

        await assertThrowsCopyError(.imageNotRenderable(itemID)) {
            try await self.service.copyToClipboard(itemID: itemID)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "baseline")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    // MARK: - Directory replay

    func testCopyToClipboardFolderReplaysAsFileURLNotPathText() async throws {
        let folderURL = baseURL.appendingPathComponent("copied-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var itemID = UUID()
        try await startService(seed: { storage in
            itemID = try await Self.insertFileItem(paths: [folderURL.path], into: storage)
        })

        try await service.copyToClipboard(itemID: itemID)

        let pastedURLs = pastedFileURLs()
        XCTAssertEqual(pastedURLs, [folderURL.standardizedFileURL])
        XCTAssertEqual(
            pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String],
            [folderURL.path]
        )
    }

    func testCopyToClipboardMixedFileAndFolderReplaysBothInCopyOrder() async throws {
        let fileURL = baseURL.appendingPathComponent("document.txt")
        try Data("hello".utf8).write(to: fileURL, options: .atomic)
        let folderURL = baseURL.appendingPathComponent("nested-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var itemID = UUID()
        try await startService(seed: { storage in
            itemID = try await Self.insertFileItem(paths: [fileURL.path, folderURL.path], into: storage)
        })

        try await service.copyToClipboard(itemID: itemID)

        XCTAssertEqual(
            pastedFileURLs(),
            [fileURL.standardizedFileURL, folderURL.standardizedFileURL],
            "A mixed selection must replay every node, in the order it was copied"
        )
    }

    func testCopyToClipboardApplicationBundleReplaysAsFileURL() async throws {
        let bundleURL = baseURL.appendingPathComponent("Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )

        var itemID = UUID()
        try await startService(seed: { storage in
            itemID = try await Self.insertFileItem(paths: [bundleURL.path], into: storage)
        })

        try await service.copyToClipboard(itemID: itemID)

        XCTAssertEqual(pastedFileURLs(), [bundleURL.standardizedFileURL])
    }

    func testCopyToClipboardFallsBackToPathTextWhenEveryRecordedNodeIsGone() async throws {
        let removedURL = baseURL.appendingPathComponent("deleted-folder", isDirectory: true)

        var itemID = UUID()
        try await startService(seed: { storage in
            itemID = try await Self.insertFileItem(paths: [removedURL.path], into: storage)
        })

        try await service.copyToClipboard(itemID: itemID)

        XCTAssertEqual(pasteboard.string(forType: .string), removedURL.path)
        XCTAssertNil(pasteboard.propertyList(forType: .init("NSFilenamesPboardType")))
    }

    // MARK: - Helpers

    private func startService(
        seed: (StorageService) async throws -> Void
    ) async throws {
        let seedStorage = StorageService(databasePath: databasePath)
        try await seedStorage.open()
        try await seed(seedStorage)
        await seedStorage.close()

        service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.1
        )
        try await service.start()
    }

    private static func insertFileItem(paths: [String], into storage: StorageService) async throws -> UUID {
        let plainText = paths.joined(separator: "\n")
        let serialized = try JSONEncoder().encode(paths)
        let item = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .file,
                plainText: plainText,
                payload: .data(serialized),
                appBundleID: "com.apple.finder",
                contentHash: UUID().uuidString,
                sizeBytes: plainText.utf8.count + serialized.count
            )
        )
        return item.id
    }

    private func useCount(of itemID: UUID) async throws -> Int {
        let readStorage = StorageService(databasePath: databasePath)
        try await readStorage.open()
        defer { Task { await readStorage.close() } }
        let item = try await readStorage.findByID(itemID)
        return try XCTUnwrap(item).useCount
    }

    private func writeBaselineClipboard() {
        pasteboard.clearContents()
        pasteboard.setString("baseline", forType: .string)
    }

    private func pastedFileURLs() -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return (urls ?? []).map { $0.standardizedFileURL }
    }

    private func assertThrowsCopyError(
        _ expected: ClipboardCopyError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected) but the copy reported success", file: file, line: line)
        } catch let error as ClipboardCopyError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected) but got \(error)", file: file, line: line)
        }
    }
}
