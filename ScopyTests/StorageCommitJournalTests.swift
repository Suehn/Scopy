import XCTest
@testable import ScopyKit

@MainActor
final class StorageCommitJournalTests: XCTestCase {
    private var repositories: [SQLiteClipboardRepository] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for repository in repositories {
            await repository.close()
        }
        repositories.removeAll()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories.removeAll()
    }

    func testReadersKeepIndependentPositionsAndMissingHistoryRequiresSnapshot() {
        let journal = StorageCommitJournal()
        journal.reset(to: 40)
        journal.append(mutationSeq: 41, totalCount: 0, change: .deleted([UUID()]))
        journal.append(mutationSeq: 42, totalCount: 0, change: .deleted([UUID()]))

        assertChanges(journal.read(after: 41), sequences: [42], through: 42)
        assertChanges(journal.read(after: 40), sequences: [41, 42], through: 42)
        assertChanges(journal.read(after: 42), sequences: [], through: 42)
        assertChanges(journal.read(after: 40, through: 41), sequences: [41], through: 41)
        assertChanges(journal.read(after: 41, through: 41), sequences: [], through: 41)
        assertSnapshotRequired(journal.read(after: 41, through: 43), through: 43)
        assertSnapshotRequired(journal.read(after: 42, through: 41), through: 41)
        assertSnapshotRequired(journal.read(after: 39), through: 42)
        assertSnapshotRequired(journal.read(after: 43), through: 42)

        journal.append(mutationSeq: 44, totalCount: 0, change: .deleted([UUID()]))
        assertSnapshotRequired(journal.read(after: 42), through: 44)
        assertSnapshotRequired(journal.read(after: 40, through: 41), through: 41)
        assertChanges(journal.read(after: 41, through: 41), sequences: [], through: 41)
        assertChanges(journal.read(after: 43), sequences: [44], through: 44)
    }

    func testEntryAndByteBoundsReportGapsAndNeverRetainPayloadBytes() throws {
        let journal = StorageCommitJournal()
        for sequence in 1...(StorageCommitJournal.capacity + 1) {
            journal.append(mutationSeq: Int64(sequence), totalCount: 0, change: .deleted([UUID()]))
        }
        let latest = Int64(StorageCommitJournal.capacity + 1)
        assertSnapshotRequired(journal.read(after: 0), through: latest)
        assertChanges(journal.read(after: 1), sequences: Array(2...latest), through: latest)

        journal.reset(to: 0)
        let largeRow = makeItem(text: String(repeating: "x", count: StorageCommitJournal.byteBudget / 2))
        journal.append(mutationSeq: 1, totalCount: 1, change: .upserted(largeRow, kind: .inserted))
        journal.append(mutationSeq: 2, totalCount: 1, change: .upserted(largeRow, kind: .usage))
        assertSnapshotRequired(journal.read(after: 0), through: 2)
        guard case .changes(let entries, _) = journal.read(after: 1),
              case .upserted(let stored, _) = try XCTUnwrap(entries.first).change else {
            return XCTFail("The newest bounded commit must remain readable")
        }
        XCTAssertNil(stored.rawData)
        XCTAssertEqual(stored.plainText, largeRow.plainText)

        let oversized = makeItem(text: String(repeating: "x", count: 8_650_772))
        journal.append(mutationSeq: 3, totalCount: 1, change: .upserted(oversized, kind: .content))
        assertSnapshotRequired(journal.read(after: 2), through: 3)
        journal.append(mutationSeq: 4, totalCount: 0, change: .deleted([oversized.id]))
        assertChanges(journal.read(after: 3), sequences: [4], through: 4)

        let payloadHeavy = makeItem(text: "summary", rawData: Data(repeating: 1, count: StorageCommitJournal.byteBudget + 1))
        journal.append(mutationSeq: 5, totalCount: 1, change: .storageSizesUpdated([payloadHeavy]))
        guard case .changes(let batchEntries, _) = journal.read(after: 4),
              case .storageSizesUpdated(let rows) = try XCTUnwrap(batchEntries.first).change else {
            return XCTFail("Raw payload size must not consume the summary budget")
        }
        XCTAssertEqual(rows.map(\.id), [payloadHeavy.id])
        XCTAssertNil(rows.first?.rawData)
        journal.append(mutationSeq: 6, totalCount: 2, change: .storageSizesUpdated([largeRow, largeRow]))
        assertSnapshotRequired(journal.read(after: 5), through: 6)
    }

    func testWakeupsIncludeRegistrationPositionAndCoalesceWithoutConsumingFacts() async {
        let journal = StorageCommitJournal()
        journal.reset(to: 12)
        var wakeups = journal.wakeups().makeAsyncIterator()
        let initial = await wakeups.next()
        XCTAssertEqual(initial, 12)

        journal.append(mutationSeq: 13, totalCount: 0, change: .deleted([UUID()]))
        journal.append(mutationSeq: 14, totalCount: 0, change: .deleted([UUID()]))
        let latest = await wakeups.next()
        XCTAssertEqual(latest, 14)
        assertChanges(journal.read(after: 12), sequences: [13, 14], through: 14)
        assertChanges(journal.read(after: 12), sequences: [13, 14], through: 14)
    }

    func testRepositoryRecordsTransactionRowsExactDeletionsAndSnapshotPosition() async throws {
        let (repository, directory) = try await makeRepository()
        let journal = repository.commitJournal
        let first = makeItem(text: "original")
        try await insert(first, into: repository)
        let initialPage = try await repository.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertEqual(initialPage.mutationSeq, 1)
        XCTAssertEqual(initialPage.items.map(\.id), [first.id])

        _ = try await repository.updateItemNoteReturningItem(id: first.id, note: "searchable note")
        _ = try await repository.updateItemNoteReturningItem(id: first.id, note: "searchable note")
        XCTAssertEqual(journal.currentMutationSeq, 2, "An unchanged note is not another commit")
        try await repository.updatePin(id: first.id, pinned: true)

        let external = makeItem(text: "external", storageRef: directory.appendingPathComponent("payload.png").path)
        try await insert(external, into: repository)
        let changed = try await repository.updateItemSizeBytesBatchInTransaction(updates: [
            .init(id: external.id, expectedContentHash: external.contentHash,
                  expectedSizeBytes: external.sizeBytes, expectedStorageRef: try XCTUnwrap(external.storageRef),
                  sizeBytes: 9)
        ])
        XCTAssertEqual(changed, 1)
        _ = try await repository.deleteAllExceptPinnedReturningStorageRefs()
        _ = try await repository.deleteAllExceptPinnedReturningStorageRefs()

        guard case .changes(let entries, let through) = journal.read(after: 0) else {
            return XCTFail("All transaction facts must be retained")
        }
        XCTAssertEqual(through, 7)
        guard entries.count == 7 else {
            return XCTFail("Expected seven committed facts, received \(entries.count)")
        }
        XCTAssertEqual(entries.map(\.mutationSeq), Array(1...7))
        XCTAssertEqual(entries.map(\.totalCount), [1, 1, 1, 2, 2, 1, 1])
        guard case .upserted(let noted, kind: .content) = entries[1].change,
              case .upserted(let pinned, kind: .pin) = entries[2].change,
              case .storageSizesUpdated(let resized) = entries[4].change,
              case .clearedUnpinned(let deleted) = entries[5].change,
              case .clearedUnpinned(let emptyClear) = entries[6].change else {
            return XCTFail("Commit kinds must describe their transaction")
        }
        XCTAssertEqual(noted.note, "searchable note")
        XCTAssertFalse(noted.isPinned, "Later writes must not replace an earlier commit's row")
        XCTAssertNil(noted.rawData)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(resized.map(\.id), [external.id])
        XCTAssertEqual(resized.first?.sizeBytes, 9)
        XCTAssertEqual(deleted, [external.id])
        XCTAssertEqual(emptyClear, [], "An empty clear remains an observable command")

        let finalPage = try await repository.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertEqual(finalPage.mutationSeq, through)
        XCTAssertEqual(finalPage.total, 1)
        XCTAssertEqual(finalPage.pinned.map(\.id), [first.id])
        XCTAssertTrue(finalPage.items.isEmpty)

        var requested = Set((0..<900).map { _ in UUID() })
        requested.formUnion([first.id, external.id])
        let selected = try await repository.fetchHistoryItems(itemIDs: requested)
        XCTAssertEqual(selected.mutationSeq, through)
        XCTAssertEqual(selected.items.map(\.id), [first.id])
        XCTAssertNil(selected.items.first?.rawData)
        let emptySelection = try await repository.fetchHistoryItems(itemIDs: [])
        XCTAssertEqual(emptySelection.mutationSeq, through)
        XCTAssertTrue(emptySelection.items.isEmpty)
        await repository.close()
        try await repository.open()
        assertSnapshotRequired(journal.read(after: 0), through: through)
        assertChanges(journal.read(after: through), sequences: [], through: through)
        await repository.close()
    }

    func testNoOpWritesAndReceiptMaintenanceDoNotAdvanceItemHistory() async throws {
        let (repository, directory) = try await makeRepository()
        let item = makeItem(text: "unchanged", storageRef: directory.appendingPathComponent("payload").path)
        try await insert(item, into: repository)
        let journal = repository.commitJournal

        try await repository.updatePin(id: item.id, pinned: false)
        try await repository.updatePin(id: UUID(), pinned: true)
        _ = try await repository.updateItemNoteReturningItem(id: item.id, note: nil)
        _ = try await repository.updateItemNoteReturningItem(id: UUID(), note: "missing")
        _ = try await repository.incrementUsageReturningCurrent(id: UUID(), lastUsedAt: Date())
        let missing = try await repository.deleteItem(id: UUID(), expectedUseCount: 1)
        XCTAssertNil(missing.item)
        XCTAssertNil(missing.storageRef)
        XCTAssertEqual(missing.mutationSeq, 1)
        _ = try await repository.commitDeletePlan(.empty)
        let unchangedPayload = try await repository.compareAndSwapItemPayload(
            expected: item, contentHash: item.contentHash, sizeBytes: item.sizeBytes,
            storageRef: item.storageRef, rawData: item.rawData
        )
        XCTAssertEqual(unchangedPayload?.id, item.id)
        let unchangedSizes = try await repository.updateItemSizeBytesBatchInTransaction(updates: [
            .init(id: item.id, expectedContentHash: item.contentHash,
                  expectedSizeBytes: item.sizeBytes, expectedStorageRef: try XCTUnwrap(item.storageRef),
                  sizeBytes: item.sizeBytes)
        ])
        XCTAssertEqual(unchangedSizes, 0)
        assertChanges(journal.read(after: 1), sequences: [], through: 1)

        let ingestID = UUID()
        _ = try await repository.commitExistingIngestIfPossible(
            ingestID: ingestID, contentHash: item.contentHash, lastUsedAt: Date()
        )
        _ = try await repository.commitExistingIngestIfPossible(
            ingestID: ingestID, contentHash: item.contentHash, lastUsedAt: Date()
        )
        _ = try await repository.resolveExistingIngestReceipt(ingestID)
        try await repository.removeIngestReceipt(ingestID)
        guard case .changes(let entries, let through) = journal.read(after: 1),
              case .upserted(let used, kind: .usage) = try XCTUnwrap(entries.first).change else {
            return XCTFail("Only the first ingest application changes item history")
        }
        XCTAssertEqual(through, 2)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(used.useCount, 2)
        XCTAssertNil(used.rawData)
    }

    func testFailedCommitPositionRollsBackRowsCountersAndJournal() async throws {
        let (repository, directory) = try await makeRepository()
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let injector = try SQLiteConnection(path: databasePath, flags: SQLiteConnection.openFlags(for: databasePath, readOnly: false))
        defer { injector.close() }
        try injector.execute(
            """
            CREATE TRIGGER fail_commit_position
            BEFORE UPDATE OF mutation_seq ON scopy_meta
            BEGIN
                SELECT RAISE(ABORT, 'injected commit position failure');
            END
            """
        )
        let item = makeItem(text: "rolled back")
        do {
            try await insert(item, into: repository)
            XCTFail("The commit position failure must abort the item transaction")
        } catch {
            XCTAssertEqual((error as? SQLiteConnection.SQLiteConnectionError)?.category, .constraint)
        }
        let afterFailure = try await repository.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertEqual(afterFailure.mutationSeq, 0)
        XCTAssertEqual(afterFailure.total, 0)
        XCTAssertTrue(afterFailure.items.isEmpty)
        assertChanges(repository.commitJournal.read(after: 0), sequences: [], through: 0)

        try injector.execute("DROP TRIGGER fail_commit_position")
        try await insert(item, into: repository)
        let afterRetry = try await repository.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertEqual(afterRetry.mutationSeq, 1)
        XCTAssertEqual(afterRetry.total, 1)
        XCTAssertEqual(afterRetry.items.map(\.id), [item.id])
        assertChanges(repository.commitJournal.read(after: 0), sequences: [1], through: 1)
    }

    #if DEBUG
    func testHistoryItemBatchesKeepTheSnapshotAcrossAnotherWALCommit() async throws {
        let (repository, directory) = try await makeRepository()
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let first = makeItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, text: "first batch")
        let last = makeItem(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, text: "last batch")
        try await insert(first, into: repository)
        try await insert(last, into: repository)
        await repository.setHistoryReadInterlockForTesting {
            let writer = try SQLiteConnection(path: databasePath, flags: SQLiteConnection.openFlags(for: databasePath, readOnly: false))
            defer { writer.close() }
            try writer.execute("BEGIN IMMEDIATE TRANSACTION")
            try writer.execute("UPDATE clipboard_items SET note = 'later commit'")
            try writer.execute("UPDATE scopy_meta SET mutation_seq = mutation_seq + 1 WHERE id = 1")
            try writer.execute("COMMIT")
        }

        var requested = Set((0..<900).map { _ in UUID() })
        requested.formUnion([first.id, last.id])
        let selected = try await repository.fetchHistoryItems(itemIDs: requested)
        XCTAssertEqual(selected.mutationSeq, 2)
        XCTAssertEqual(selected.items.map(\.id), [first.id, last.id])
        XCTAssertEqual(selected.items.map(\.note), [nil, nil])
        XCTAssertTrue(selected.items.allSatisfy { $0.rawData == nil })

        await repository.setHistoryReadInterlockForTesting(nil)
        let current = try await repository.fetchHistoryItems(itemIDs: [first.id, last.id])
        XCTAssertEqual(current.mutationSeq, 3)
        XCTAssertEqual(current.items.map(\.note), ["later commit", "later commit"])
    }
    #endif

    private func assertChanges(_ result: StorageCommitJournal.ReadResult, sequences: [Int64], through: Int64,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .changes(let entries, let actualThrough) = result else {
            return XCTFail("Expected retained changes", file: file, line: line)
        }
        XCTAssertEqual(entries.map(\.mutationSeq), sequences, file: file, line: line)
        XCTAssertEqual(actualThrough, through, file: file, line: line)
    }

    private func assertSnapshotRequired(_ result: StorageCommitJournal.ReadResult, through: Int64,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard case .resnapshotRequired(let actualThrough) = result else {
            return XCTFail("Missing history must require a snapshot", file: file, line: line)
        }
        XCTAssertEqual(actualThrough, through, file: file, line: line)
    }

    private func makeItem(id: UUID = UUID(), text: String, storageRef: String? = nil, rawData: Data? = nil) -> ClipboardStoredItem {
        ClipboardStoredItem(id: id, type: .text, contentHash: UUID().uuidString, plainText: text,
                            note: nil, appBundleID: nil, createdAt: Date(), lastUsedAt: Date(),
                            useCount: 1, isPinned: false, sizeBytes: 16, fileSizeBytes: nil,
                            storageRef: storageRef, rawData: storageRef == nil ? rawData ?? Data(repeating: 1, count: 16) : nil)
    }

    private func makeRepository() async throws -> (SQLiteClipboardRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopyCommitJournal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let repository = SQLiteClipboardRepository(dbPath: directory.appendingPathComponent("clipboard.db").path)
        repositories.append(repository)
        try await repository.open()
        return (repository, directory)
    }

    private func insert(_ item: ClipboardStoredItem, into repository: SQLiteClipboardRepository) async throws {
        try await repository.insertItem(
            id: item.id, type: item.type, contentHash: item.contentHash, plainText: item.plainText,
            note: item.note, appBundleID: item.appBundleID, createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt, sizeBytes: item.sizeBytes, fileSizeBytes: item.fileSizeBytes,
            storageRef: item.storageRef, rawData: item.rawData
        )
    }
}
