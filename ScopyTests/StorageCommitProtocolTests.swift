import AppKit
import SQLite3
import XCTest
@testable import ScopyKit

private actor IngestReceiptResolutionGate {
    private var candidatePath: String?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause(candidatePath: String?) async {
        self.candidatePath = candidatePath
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async -> String? {
        if candidatePath != nil { return candidatePath }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
        return candidatePath
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class StorageCommitProtocolTests: XCTestCase {
    private struct EnvelopeFixture: Codable {
        let id: UUID
        let typeRawValue: String
        let plainText: String
        let appBundleID: String?
        let sizeBytes: Int
        let precomputedHash: String?
        let imageDataWasTIFF: Bool
        let payloadFileName: String?
    }

    private var temporaryDirectories: [URL] = []
    private var storages: [StorageService] = []

    override func tearDown() async throws {
        for storage in storages.reversed() {
            await storage.close()
        }
        storages.removeAll()
        for directory in temporaryDirectories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testIngestReceiptMakesNewItemReplayExactlyOnce() async throws {
        let storage = try await makeStorage(prefix: "scopy-ingest-receipt-new")
        let ingestID = UUID()
        let content = makeInlineContent(text: "exact-once-new", ingestID: ingestID)

        let first = try await storage.upsertItemWithOutcome(content)
        guard case .inserted(let inserted) = first else {
            return XCTFail("First envelope application must insert")
        }
        XCTAssertEqual(inserted.useCount, 1)
        let receiptCount = try await storage.repository.ingestReceiptCount()
        XCTAssertEqual(receiptCount, 1)

        let replay = try await storage.upsertItemWithOutcome(content)
        guard case .alreadyApplied(let replayed) = replay else {
            return XCTFail("Receipt replay must be a no-op")
        }
        XCTAssertEqual(replayed?.id, inserted.id)
        let replayedItem = try await storage.findByID(inserted.id)
        let itemCount = try await storage.getItemCount()
        XCTAssertEqual(replayedItem?.useCount, 1)
        XCTAssertEqual(itemCount, 1)
    }

    func testIngestReceiptMakesExistingHashReplayIncrementOnlyOnce() async throws {
        let storage = try await makeStorage(prefix: "scopy-ingest-receipt-dedup")
        let seed = makeInlineContent(text: "existing-hash", ingestID: nil)
        let seeded = try await storage.upsertItem(seed)
        let ingestID = UUID()
        let incoming = makeInlineContent(text: "existing-hash", ingestID: ingestID)

        let first = try await storage.upsertItemWithOutcome(incoming)
        guard case .updated(let updated) = first else {
            return XCTFail("First distinct envelope must record one deduplicated use")
        }
        XCTAssertEqual(updated.id, seeded.id)
        XCTAssertEqual(updated.useCount, 2)

        let replay = try await storage.upsertItemWithOutcome(incoming)
        guard case .alreadyApplied(let replayed) = replay else {
            return XCTFail("Same envelope must not increment twice")
        }
        XCTAssertEqual(replayed?.useCount, 2)
        let current = try await storage.findByID(seeded.id)
        XCTAssertEqual(current?.useCount, 2)
    }

    func testReceiptPreventsDeletedItemResurrection() async throws {
        let storage = try await makeStorage(prefix: "scopy-ingest-receipt-delete")
        let ingestID = UUID()
        let content = makeInlineContent(text: "delete-before-replay", ingestID: ingestID)
        let inserted = try await storage.upsertItem(content)
        try await storage.deleteItem(inserted.id)

        let replay = try await storage.upsertItemWithOutcome(content)
        guard case .alreadyApplied(let item) = replay else {
            return XCTFail("Receipt must remain authoritative after item deletion")
        }
        XCTAssertNil(item)
        let count = try await storage.getItemCount()
        XCTAssertEqual(count, 0)
    }

    func testInsertFailureRetainsDurableSpoolSource() async throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-ingest-retained-source")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: databasePath, storageRootURL: directory)
        storages.append(storage)
        try await storage.open()

        let injector = try SQLiteConnection(
            path: databasePath,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        )
        try injector.execute(
            """
            CREATE TRIGGER fail_ingest_insert
            BEFORE INSERT ON clipboard_items
            BEGIN
                SELECT RAISE(ABORT, 'forced ingest failure');
            END
            """
        )

        let ingestID = UUID()
        let sourceURL = directory.appendingPathComponent("\(ingestID.uuidString).payload")
        let sourceData = Data(repeating: 0x5A, count: StorageService.externalStorageThreshold + 8_192)
        try sourceData.write(to: sourceURL)
        let content = ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "retained source",
            payload: .file(sourceURL),
            appBundleID: "com.test.storage-commit",
            contentHash: ClipboardMonitor.computeHashStatic(sourceData),
            sizeBytes: sourceData.count,
            ingestID: ingestID,
            fileOwnership: .durableSpool
        )

        do {
            _ = try await storage.upsertItemWithOutcome(content)
            XCTFail("Injected insert failure must escape")
        } catch {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        let itemCount = try await storage.getItemCount()
        let receiptCount = try await storage.repository.ingestReceiptCount()
        XCTAssertEqual(itemCount, 0)
        XCTAssertEqual(receiptCount, 0)
        let contentDirectory = directory.appendingPathComponent("content", isDirectory: true)
        let managedFiles = try FileManager.default.contentsOfDirectory(atPath: contentDirectory.path)
        XCTAssertTrue(managedFiles.isEmpty, "Failed ingest candidate must be reclaimed")
    }

    func testReceiptResolutionKeepsFailedCandidateProtectedFromOrphanCleanup() async throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-ingest-resolution-guard")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: databasePath, storageRootURL: directory)
        storages.append(storage)
        try await storage.open()

        let injector = try SQLiteConnection(
            path: databasePath,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        )
        try injector.execute(
            """
            CREATE TRIGGER fail_guarded_ingest_insert
            BEFORE INSERT ON clipboard_items
            BEGIN
                SELECT RAISE(ABORT, 'forced guarded ingest failure');
            END
            """
        )

        let ingestID = UUID()
        let sourceURL = directory.appendingPathComponent("\(ingestID.uuidString).payload")
        let sourceData = Data(repeating: 0x6B, count: StorageService.externalStorageThreshold + 4_096)
        try sourceData.write(to: sourceURL)
        let content = ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "guarded retained source",
            payload: .file(sourceURL),
            appBundleID: "com.test.storage-commit",
            contentHash: ClipboardMonitor.computeHashStatic(sourceData),
            sizeBytes: sourceData.count,
            ingestID: ingestID,
            fileOwnership: .durableSpool
        )

        let gate = IngestReceiptResolutionGate()
        storage.setIngestCommitInterlockForTesting { point in
            guard case .beforeReceiptResolution(let candidatePath) = point else { return }
            await gate.pause(candidatePath: candidatePath)
        }
        let upsert = Task { try await storage.upsertItemWithOutcome(content) }
        let pausedCandidatePath = await gate.waitUntilPaused()
        let candidatePath = try XCTUnwrap(pausedCandidatePath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: candidatePath))
        try await storage.cleanupOrphanedFiles()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: candidatePath),
            "Receipt resolution must retain the candidate cleanup guard"
        )

        await gate.release()
        do {
            _ = try await upsert.value
            XCTFail("Injected insert failure must escape")
        } catch {
            // Expected after receipt resolution proves the transaction did not commit.
        }
        storage.setIngestCommitInterlockForTesting(nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: candidatePath))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testSchemaVersionSevenMigratesToReceiptVersionEight() async throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-ingest-v8-migration")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let initial = StorageService(databasePath: databasePath, storageRootURL: directory)
        try await initial.open()
        await initial.close()

        let mutator = try SQLiteConnection(
            path: databasePath,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        )
        try mutator.execute("DROP TABLE ingest_receipts")
        try mutator.execute("PRAGMA user_version = 7")
        mutator.close()

        let migrated = StorageService(databasePath: databasePath, storageRootURL: directory)
        storages.append(migrated)
        try await migrated.open()

        let inspector = try SQLiteConnection(
            path: databasePath,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )
        let version = try inspector.prepare("PRAGMA user_version")
        XCTAssertTrue(try version.step())
        XCTAssertEqual(version.columnInt(0), 8)
        let receiptTable = try inspector.prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ingest_receipts'"
        )
        XCTAssertTrue(try receiptTable.step())
        XCTAssertEqual(receiptTable.columnInt(0), 1)
        let integrity = try inspector.prepare("PRAGMA integrity_check")
        XCTAssertTrue(try integrity.step())
        XCTAssertEqual(integrity.columnText(0), "ok")
    }

    func testTerminalAcknowledgementIsRecoverableAndContained() throws {
        let spool = try makeTemporaryDirectory(prefix: "scopy-ingest-terminal")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("scopy-terminal-\(UUID().uuidString)"))
        let monitor = ClipboardMonitor(pasteboard: pasteboard, ingestSpoolDirectory: spool)
        let id = UUID()
        let payload = Data(repeating: 0x2A, count: 4_096)
        let envelopeURL = try writeEnvelope(id: id, payload: payload, in: spool)

        let acknowledgement: ClipboardMonitor.TerminalIngestAcknowledgement
        switch monitor.acknowledgeIngestEnvelope(at: envelopeURL) {
        case .terminal(let terminal):
            acknowledgement = terminal
        case .rejected:
            return XCTFail("Owned pending envelope should transition to terminal")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertEqual(monitor.pendingTerminalIngestAcknowledgements().map(\.ingestID), [id])

        let restarted = ClipboardMonitor(pasteboard: pasteboard, ingestSpoolDirectory: spool)
        let recovered = try XCTUnwrap(restarted.pendingTerminalIngestAcknowledgements().first)
        XCTAssertEqual(recovered.ingestID, acknowledgement.ingestID)
        XCTAssertTrue(restarted.completeTerminalIngestAcknowledgement(recovered))
        XCTAssertTrue(restarted.pendingTerminalIngestAcknowledgements().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: spool.appendingPathComponent("\(id.uuidString).payload").path
            )
        )

        let foreignDirectory = try makeTemporaryDirectory(prefix: "scopy-ingest-foreign")
        let foreignEnvelope = try writeEnvelope(id: UUID(), payload: Data([1, 2, 3]), in: foreignDirectory)
        guard case .rejected = monitor.acknowledgeIngestEnvelope(at: foreignEnvelope) else {
            return XCTFail("Foreign acknowledgement URL must fail closed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignEnvelope.path))
    }

    func testPayloadTraversalAndSymlinkEscapeFailClosed() throws {
        let spool = try makeTemporaryDirectory(prefix: "scopy-ingest-containment")
        let outside = try makeTemporaryDirectory(prefix: "scopy-ingest-outside")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("scopy-containment-\(UUID().uuidString)"))
        let monitor = ClipboardMonitor(pasteboard: pasteboard, ingestSpoolDirectory: spool)

        let traversalID = UUID()
        let outsideVictim = outside.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: outsideVictim)
        let traversalEnvelope = try writeEnvelope(
            id: traversalID,
            payloadFileName: "../\(outsideVictim.lastPathComponent)",
            in: spool
        )
        guard case .rejected = monitor.acknowledgeIngestEnvelope(at: traversalEnvelope) else {
            return XCTFail("Traversal payload filename must reject acknowledgement")
        }
        XCTAssertEqual(try Data(contentsOf: outsideVictim), Data("keep".utf8))

        let symlinkID = UUID()
        let symlinkEnvelope = try writeEnvelope(
            id: symlinkID,
            payloadFileName: "\(symlinkID.uuidString).payload",
            in: spool
        )
        let symlinkPayload = spool.appendingPathComponent("\(symlinkID.uuidString).payload")
        try FileManager.default.createSymbolicLink(at: symlinkPayload, withDestinationURL: outsideVictim)
        let terminal: ClipboardMonitor.TerminalIngestAcknowledgement
        switch monitor.acknowledgeIngestEnvelope(at: symlinkEnvelope) {
        case .terminal(let value): terminal = value
        case .rejected: return XCTFail("Envelope itself is owned and may become terminal")
        }
        XCTAssertFalse(monitor.completeTerminalIngestAcknowledgement(terminal))
        XCTAssertEqual(try Data(contentsOf: outsideVictim), Data("keep".utf8))
        XCTAssertEqual(monitor.pendingTerminalIngestAcknowledgements().map(\.ingestID), [symlinkID])
    }

    func testLegacyPendingPairMigrationRemainsReplayable() async throws {
        let legacy = try makeTemporaryDirectory(prefix: "scopy-ingest-legacy")
        let current = try makeTemporaryDirectory(prefix: "scopy-ingest-current")
        let id = UUID()
        let payload = Data(repeating: 0x7C, count: 8_192)
        let legacyEnvelope = try writeEnvelope(id: id, payload: payload, in: legacy)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("scopy-migration-\(UUID().uuidString)"))

        await Task.detached(priority: .utility) {
            ClipboardMonitor.prepareIngestSpoolDirectory(
                current,
                legacyDirectory: legacy
            )
        }.value

        _ = ClipboardMonitor(
            pasteboard: pasteboard,
            pollingInterval: nil,
            ingestSpoolDirectory: current,
            legacyIngestSpoolDirectory: legacy,
            spoolAlreadyPrepared: true
        )

        let currentEnvelope = current.appendingPathComponent(legacyEnvelope.lastPathComponent)
        let currentPayload = current.appendingPathComponent("\(id.uuidString).payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentEnvelope.path))
        XCTAssertEqual(try Data(contentsOf: currentPayload), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyEnvelope.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("\(id.uuidString).payload").path
            )
        )
    }

    func testStaleStandalonePayloadIsReclaimedButEnvelopeOwnedPayloadRemains() throws {
        let spool = try makeTemporaryDirectory(prefix: "scopy-ingest-orphan-payload")
        let orphanID = UUID()
        let orphanURL = spool.appendingPathComponent("\(orphanID.uuidString).payload")
        try Data("orphan".utf8).write(to: orphanURL)

        let liveID = UUID()
        let liveEnvelope = try writeEnvelope(
            id: liveID,
            payload: Data("live".utf8),
            in: spool
        )
        let livePayload = spool.appendingPathComponent("\(liveID.uuidString).payload")
        let staleDate = Date().addingTimeInterval(-(25 * 60 * 60))
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: orphanURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: livePayload.path
        )

        ClipboardMonitor.prepareIngestSpoolDirectory(spool, legacyDirectory: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveEnvelope.path))
        XCTAssertEqual(try Data(contentsOf: livePayload), Data("live".utf8))
    }

    func testLegacyMigrationRejectsDestinationSymlinkWithoutDeletingSource() throws {
        let legacy = try makeTemporaryDirectory(prefix: "scopy-ingest-legacy-symlink")
        let current = try makeTemporaryDirectory(prefix: "scopy-ingest-current-symlink")
        let outside = try makeTemporaryDirectory(prefix: "scopy-ingest-migration-outside")
        let id = UUID()
        let payload = Data("preserve legacy source".utf8)
        let legacyEnvelope = try writeEnvelope(id: id, payload: payload, in: legacy)
        let legacyPayload = legacy.appendingPathComponent("\(id.uuidString).payload")
        let outsideVictim = outside.appendingPathComponent("victim")
        try payload.write(to: outsideVictim)
        let destinationPayload = current.appendingPathComponent("\(id.uuidString).payload")
        try FileManager.default.createSymbolicLink(
            at: destinationPayload,
            withDestinationURL: outsideVictim
        )

        ClipboardMonitor.prepareIngestSpoolDirectory(
            current,
            legacyDirectory: legacy
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyEnvelope.path))
        XCTAssertEqual(try Data(contentsOf: legacyPayload), payload)
        XCTAssertEqual(try Data(contentsOf: outsideVictim), payload)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: current.appendingPathComponent(legacyEnvelope.lastPathComponent).path
            )
        )
    }

    func testDurablePngquantWorkCopyNeverMutatesEnvelopePayload() throws {
        let spool = try makeTemporaryDirectory(prefix: "scopy-ingest-work-copy")
        let id = UUID()
        let original = Data(repeating: 0x33, count: 2_048)
        let envelopeURL = try writeEnvelope(id: id, payload: original, in: spool)
        let payloadURL = spool.appendingPathComponent("\(id.uuidString).payload")
        let content = ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "work copy",
            payload: .file(payloadURL),
            appBundleID: nil,
            contentHash: ClipboardMonitor.computeHashStatic(original),
            sizeBytes: original.count,
            ingestEnvelopeURL: envelopeURL,
            ingestID: id,
            fileOwnership: .durableSpool
        )

        let workURL = try ClipboardMonitor.createTransientWorkCopy(for: content)
        defer { try? FileManager.default.removeItem(at: workURL) }
        try Data([0x01]).write(to: workURL)
        XCTAssertEqual(try Data(contentsOf: payloadURL), original)
        XCTAssertTrue(workURL.lastPathComponent.hasPrefix(".ingest-work-"))
    }

    private func makeInlineContent(
        text: String,
        ingestID: UUID?
    ) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            payload: .none,
            appBundleID: "com.test.storage-commit",
            contentHash: ClipboardMonitor.computeHashStatic(Data(text.utf8)),
            sizeBytes: text.utf8.count,
            ingestID: ingestID
        )
    }

    private func makeStorage(prefix: String) async throws -> StorageService {
        let directory = try makeTemporaryDirectory(prefix: prefix)
        let storage = StorageService(
            databasePath: directory.appendingPathComponent("clipboard.db").path,
            storageRootURL: directory
        )
        storages.append(storage)
        try await storage.open()
        return storage
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    @discardableResult
    private func writeEnvelope(id: UUID, payload: Data, in directory: URL) throws -> URL {
        let payloadFileName = "\(id.uuidString).payload"
        try payload.write(to: directory.appendingPathComponent(payloadFileName))
        return try writeEnvelope(id: id, payloadFileName: payloadFileName, in: directory)
    }

    private func writeEnvelope(
        id: UUID,
        payloadFileName: String?,
        in directory: URL
    ) throws -> URL {
        let fixture = EnvelopeFixture(
            id: id,
            typeRawValue: ClipboardItemType.image.rawValue,
            plainText: "[Image]",
            appBundleID: "com.test.storage-commit",
            sizeBytes: 4_096,
            precomputedHash: nil,
            imageDataWasTIFF: false,
            payloadFileName: payloadFileName
        )
        let envelopeURL = directory.appendingPathComponent("\(id.uuidString).envelope.json")
        try JSONEncoder().encode(fixture).write(to: envelopeURL)
        return envelopeURL
    }
}
