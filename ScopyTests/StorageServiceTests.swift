import XCTest
@testable import ScopyKit

private actor StorageMetadataUpdateGate {
    private var isPaused = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor FirstMetadataDTOGate {
    private var didPause = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard !didPause else { return }
        didPause = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor StorageIntBox {
    private var value = 0

    func set(_ newValue: Int) {
        value = newValue
    }

    func get() -> Int {
        value
    }
}

private actor CleanupFailureProbe {
    private var committedBatches: [[UUID]] = []
    private var didInstallFailureTrigger = false
    private var triggerError: String?

    func recordAndInstallFailure(after result: StorageService.CleanupResult, dbPath: String) {
        committedBatches.append(result.deletedItemIDs)
        guard !didInstallFailureTrigger else { return }
        didInstallFailureTrigger = true
        do {
            let flags = SQLiteConnection.openFlags(for: dbPath, readOnly: false)
            let connection = try SQLiteConnection(path: dbPath, flags: flags)
            defer { connection.close() }
            try connection.execute(
                """
                CREATE TRIGGER fail_later_cleanup_delete
                BEFORE DELETE ON clipboard_items
                BEGIN
                    SELECT RAISE(ABORT, 'injected later cleanup failure');
                END
                """
            )
        } catch {
            triggerError = error.localizedDescription
        }
    }

    func snapshot() -> (batches: [[UUID]], triggerError: String?) {
        (committedBatches, triggerError)
    }
}

/// StorageService 单元测试
/// 验证 v0.md 第2、3节的存储和去重要求
@MainActor
final class StorageServiceTests: XCTestCase {

    var storage: StorageService!
    private var raceStorages: [StorageService] = []
    private var raceStorageDirectories: [URL] = []
    private var clipboardServices: [ClipboardService] = []
    private var settingsSuiteNames: [String] = []

    private final class RemoveFileProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        func recordCall() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    override func setUp() async throws {
        // Use in-memory database for testing
        storage = StorageService(databasePath: ":memory:")
        try await storage.open()
    }

    override func tearDown() async throws {
        for service in clipboardServices.reversed() {
            await service.stop()
        }
        clipboardServices.removeAll()
        for raceStorage in raceStorages.reversed() {
            await raceStorage.close()
        }
        raceStorages.removeAll()
        await storage.close()
        storage = nil
        for directory in raceStorageDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        raceStorageDirectories.removeAll()
        for suiteName in settingsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        settingsSuiteNames.removeAll()
    }

    // MARK: - Basic CRUD Tests

    func testInsertAndRetrieve() async throws {
        let content = makeTestContent(text: "Hello, World!")
        let item = try await storage.upsertItem(content)

        XCTAssertEqual(item.plainText, "Hello, World!")
        XCTAssertEqual(item.type, .text)
        XCTAssertFalse(item.isPinned)

        let retrieved = try await storage.findByID(item.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.plainText, "Hello, World!")
    }

    func testFetchRecent() async throws {
        // Insert multiple items
        for i in 0..<10 {
            let content = makeTestContent(text: "Item \(i)")
            _ = try await storage.upsertItem(content)
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms delay for ordering
        }

        // Fetch with pagination
        let page1 = try await storage.fetchRecent(limit: 5, offset: 0)
        XCTAssertEqual(page1.count, 5)

        let page2 = try await storage.fetchRecent(limit: 5, offset: 5)
        XCTAssertEqual(page2.count, 5)

        // Items should be different
        let ids1 = Set(page1.map { $0.id })
        let ids2 = Set(page2.map { $0.id })
        XCTAssertTrue(ids1.isDisjoint(with: ids2))
    }

    func testDelete() async throws {
        let content = makeTestContent(text: "To be deleted")
        let item = try await storage.upsertItem(content)

        // Verify exists
        let existing = try await storage.findByID(item.id)
        XCTAssertNotNil(existing)

        // Delete
        try await storage.deleteItem(item.id)

        // Verify deleted
        let missing = try await storage.findByID(item.id)
        XCTAssertNil(missing)
    }

    func testAtomicNoteUpdateReturnsPayloadReplacementThatWonBeforeTransaction() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(prefix: "note-payload-race")
        let item = try await primary.upsertItem(makeTestContent(text: "note race"))
        let gate = StorageMetadataUpdateGate()
        await primary.repository.setMetadataUpdateInterlockForTesting { kind, id in
            guard case .note = kind, id == item.id else { return }
            await gate.pause()
        }

        let noteUpdate = Task {
            try await primary.updateNote(id: item.id, note: "latest note")
        }
        await gate.waitUntilPaused()

        let replacementData = Data("replacement payload".utf8)
        let replacementHash = "replacement-\(UUID().uuidString)"
        do {
            try await competing.updateItemPayload(
                id: item.id,
                contentHash: replacementHash,
                sizeBytes: replacementData.count,
                storageRef: nil,
                rawData: replacementData
            )
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        let noteUpdateResult = try await noteUpdate.value
        let updated = try XCTUnwrap(noteUpdateResult)
        XCTAssertEqual(updated.note, "latest note")
        XCTAssertEqual(updated.contentHash, replacementHash)
        XCTAssertEqual(updated.sizeBytes, replacementData.count)
        XCTAssertEqual(updated.rawData, replacementData)

        let persistedResult = try await primary.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.note, "latest note")
        XCTAssertEqual(persisted.contentHash, replacementHash)
        XCTAssertEqual(persisted.rawData, replacementData)
    }

    func testAtomicNoteUpdateReturnsNilWhenDeleteWinsBeforeTransaction() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(prefix: "note-delete-race")
        let item = try await primary.upsertItem(makeTestContent(text: "note delete race"))
        let gate = StorageMetadataUpdateGate()
        await primary.repository.setMetadataUpdateInterlockForTesting { kind, id in
            guard case .note = kind, id == item.id else { return }
            await gate.pause()
        }

        let noteUpdate = Task {
            try await primary.updateNote(id: item.id, note: "must not become a ghost")
        }
        await gate.waitUntilPaused()
        do {
            try await competing.deleteItem(item.id)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        let noteUpdateResult = try await noteUpdate.value
        let persisted = try await primary.findByID(item.id)
        XCTAssertNil(noteUpdateResult)
        XCTAssertNil(persisted)
    }

    func testAtomicFileSizeUpdateRejectsPayloadReplacementThatWonBeforeTransaction() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(prefix: "file-size-payload-race")
        let item = try await primary.upsertItem(makeTestContent(text: "file size race", type: .file))
        let gate = StorageMetadataUpdateGate()
        await primary.repository.setMetadataUpdateInterlockForTesting { kind, id in
            guard case .fileSizeBytes = kind, id == item.id else { return }
            await gate.pause()
        }

        let fileSizeUpdate = Task {
            try await primary.updateFileSizeBytes(expected: item, fileSizeBytes: 4_096)
        }
        await gate.waitUntilPaused()

        let replacementData = Data("new file payload".utf8)
        let replacementHash = "replacement-\(UUID().uuidString)"
        do {
            try await competing.updateItemPayload(
                id: item.id,
                contentHash: replacementHash,
                sizeBytes: replacementData.count,
                storageRef: nil,
                rawData: replacementData
            )
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        let fileSizeUpdateResult = try await fileSizeUpdate.value
        XCTAssertNil(fileSizeUpdateResult)

        let persistedResult = try await primary.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertNil(persisted.fileSizeBytes)
        XCTAssertEqual(persisted.contentHash, replacementHash)
        XCTAssertEqual(persisted.rawData, replacementData)
    }

    func testAtomicFileSizeUpdateReturnsNilWhenDeleteWinsBeforeTransaction() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(prefix: "file-size-delete-race")
        let item = try await primary.upsertItem(makeTestContent(text: "file size delete race", type: .file))
        let gate = StorageMetadataUpdateGate()
        await primary.repository.setMetadataUpdateInterlockForTesting { kind, id in
            guard case .fileSizeBytes = kind, id == item.id else { return }
            await gate.pause()
        }

        let fileSizeUpdate = Task {
            try await primary.updateFileSizeBytes(expected: item, fileSizeBytes: 8_192)
        }
        await gate.waitUntilPaused()
        do {
            try await competing.deleteItem(item.id)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        let fileSizeUpdateResult = try await fileSizeUpdate.value
        let persisted = try await primary.findByID(item.id)
        XCTAssertNil(fileSizeUpdateResult)
        XCTAssertNil(persisted)
    }

    func testDeleteAllExceptPinned() async throws {
        // Insert some items
        for i in 0..<5 {
            let content = makeTestContent(text: "Item \(i)")
            _ = try await storage.upsertItem(content)
        }

        // Pin one item
        let items = try await storage.fetchRecent(limit: 10, offset: 0)
        let itemToPin = items[0]
        try await storage.setPin(itemToPin.id, pinned: true)

        // Clear all except pinned
        try await storage.deleteAllExceptPinned()

        // Should only have 1 item left
        let remaining = try await storage.fetchRecent(limit: 10, offset: 0)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].isPinned)
    }

    func testClearThumbnailCacheWaitsForDirectoryReset() async throws {
        let fileManager = FileManager.default
        let thumbnailDirectory = storage.thumbnailCacheDirectoryPath
        let thumbnailURL = URL(fileURLWithPath: thumbnailDirectory).appendingPathComponent("stale.png")

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: thumbnailURL)
        XCTAssertTrue(fileManager.fileExists(atPath: thumbnailURL.path))

        await storage.clearThumbnailCache()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: thumbnailDirectory, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(fileManager.fileExists(atPath: thumbnailURL.path))
    }

    func testThumbnailCacheIndexDropsMissingIndexedPath() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let filename = "thumb.png"
        let thumbnailURL = rootURL.appendingPathComponent(filename)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: thumbnailURL)

        var index = ClipboardService.ThumbnailCacheIndex(root: rootURL.path, filenames: [filename])
        XCTAssertEqual(index.pathIfExists(filename: filename), thumbnailURL.path)

        try fileManager.removeItem(at: thumbnailURL)

        XCTAssertNil(index.pathIfExists(filename: filename))
        XCTAssertFalse(index.filenames.contains(filename))
    }

    // MARK: - Deduplication Tests (v0.md 3.2)

    func testDeduplication() async throws {
        let content1 = makeTestContent(text: "Duplicate content")
        let item1 = try await storage.upsertItem(content1)

        // Same content should not create new item
        let content2 = makeTestContent(text: "Duplicate content")
        let item2 = try await storage.upsertItem(content2)

        // Same ID means dedup worked
        XCTAssertEqual(item1.id, item2.id)

        // Use count should be incremented
        let retrieved = try await storage.findByID(item1.id)
        XCTAssertEqual(retrieved?.useCount, 2)

        // Total count should be 1
        let count = try await storage.getItemCount()
        XCTAssertEqual(count, 1)
    }

    func testConcurrentUsageIncrementsAccumulateAndPreserveCurrentMetadata() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(
            prefix: "usage-increment-race"
        )
        let item = try await primary.upsertItem(makeTestContent(text: "usage race"))
        try await primary.setPin(item.id, pinned: true)
        let newerTimestamp = Date().addingTimeInterval(10)

        let olderIncrement = Task {
            try await primary.incrementUsage(id: item.id, at: Date(timeIntervalSince1970: 1))
        }
        let newerIncrement = Task {
            try await competing.incrementUsage(id: item.id, at: newerTimestamp)
        }
        _ = try await olderIncrement.value
        _ = try await newerIncrement.value

        let persistedResult = try await primary.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.useCount, item.useCount + 2)
        XCTAssertTrue(persisted.isPinned)
        XCTAssertEqual(
            persisted.lastUsedAt.timeIntervalSince1970,
            newerTimestamp.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(persisted.contentHash, item.contentHash)
    }

    func testDeduplicationWithNormalization() async throws {
        // Text with leading/trailing whitespace
        let content1 = makeTestContent(text: "   Normalized text   \n\r\n")
        let item1 = try await storage.upsertItem(content1)

        // Same normalized text
        let content2 = makeTestContent(text: "Normalized text")
        let item2 = try await storage.upsertItem(content2)

        // Should be deduplicated
        XCTAssertEqual(item1.id, item2.id)
    }

    func testDifferentContentNotDeduplicated() async throws {
        let content1 = makeTestContent(text: "Content A")
        _ = try await storage.upsertItem(content1)

        let content2 = makeTestContent(text: "Content B")
        _ = try await storage.upsertItem(content2)

        // Should have 2 items
        let count = try await storage.getItemCount()
        XCTAssertEqual(count, 2)
    }

    // MARK: - Pin Tests

    func testPinAndUnpin() async throws {
        let content = makeTestContent(text: "Pinnable item")
        let item = try await storage.upsertItem(content)

        XCTAssertFalse(item.isPinned)

        // Pin
        try await storage.setPin(item.id, pinned: true)
        var retrieved = try await storage.findByID(item.id)
        XCTAssertTrue(retrieved?.isPinned ?? false)

        // Unpin
        try await storage.setPin(item.id, pinned: false)
        retrieved = try await storage.findByID(item.id)
        XCTAssertFalse(retrieved?.isPinned ?? true)
    }

    func testPinnedItemsFirst() async throws {
        // Insert 5 items
        for i in 0..<5 {
            let content = makeTestContent(text: "Item \(i)")
            _ = try await storage.upsertItem(content)
        }

        // Pin the third item
        let items = try await storage.fetchRecent(limit: 10, offset: 0)
        try await storage.setPin(items[2].id, pinned: true)

        // Fetch again - pinned should be first
        let fetched = try await storage.fetchRecent(limit: 10, offset: 0)
        XCTAssertTrue(fetched[0].isPinned)
    }

    // MARK: - Statistics Tests

    func testItemCount() async throws {
        let initialCount = try await storage.getItemCount()
        XCTAssertEqual(initialCount, 0)

        for i in 0..<10 {
            let content = makeTestContent(text: "Item \(i)")
            _ = try await storage.upsertItem(content)
        }

        let finalCount = try await storage.getItemCount()
        XCTAssertEqual(finalCount, 10)
    }

    func testTotalSize() async throws {
        let initialSize = try await storage.getTotalSize()
        XCTAssertEqual(initialSize, 0)

        let content = makeTestContent(text: "12345") // 5 bytes
        _ = try await storage.upsertItem(content)

        let size = try await storage.getTotalSize()
        XCTAssertEqual(size, 5)
    }

    func testLargeByteCountsPersistAcrossDiskReopenAndMetadataUpdates() async throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-large-byte-count")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let initialSize = Int(Int32.max) + 1_337
        let initialFileSize = 5 * 1024 * 1024 * 1024

        let initialStorage = StorageService(databasePath: databasePath)
        raceStorages.append(initialStorage)
        raceStorageDirectories.append(directory)
        try await initialStorage.open()

        let inserted = try await initialStorage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .file,
                plainText: "/tmp/scopy-synthetic-large-file",
                payload: .none,
                appBundleID: "com.test.large-file",
                contentHash: "large-file-\(UUID().uuidString)",
                sizeBytes: initialSize,
                fileSizeBytes: initialFileSize
            )
        )
        XCTAssertEqual(inserted.sizeBytes, initialSize)
        XCTAssertEqual(inserted.fileSizeBytes, initialFileSize)
        let initialTotalSize = try await initialStorage.getTotalSize()
        XCTAssertEqual(initialTotalSize, initialSize)
        await initialStorage.close()

        let reopenedStorage = StorageService(databasePath: databasePath)
        raceStorages.append(reopenedStorage)
        try await reopenedStorage.open()

        let reopenedResult = try await reopenedStorage.findByID(inserted.id)
        let reopened = try XCTUnwrap(reopenedResult)
        XCTAssertEqual(reopened.sizeBytes, initialSize)
        XCTAssertEqual(reopened.fileSizeBytes, initialFileSize)

        let updatedSize = initialSize + 4_096
        try await reopenedStorage.updateItemPayload(
            id: reopened.id,
            contentHash: reopened.contentHash,
            sizeBytes: updatedSize,
            storageRef: nil,
            rawData: nil
        )
        let payloadUpdatedResult = try await reopenedStorage.findByID(reopened.id)
        let payloadUpdated = try XCTUnwrap(payloadUpdatedResult)
        let updatedFileSize = initialFileSize + 8_192
        let metadataUpdatedResult = try await reopenedStorage.updateFileSizeBytes(
            expected: payloadUpdated,
            fileSizeBytes: updatedFileSize
        )
        let metadataUpdated = try XCTUnwrap(metadataUpdatedResult)

        XCTAssertEqual(metadataUpdated.sizeBytes, updatedSize)
        XCTAssertEqual(metadataUpdated.fileSizeBytes, updatedFileSize)
        let updatedTotalSize = try await reopenedStorage.getTotalSize()
        XCTAssertEqual(updatedTotalSize, updatedSize)
        await reopenedStorage.close()

        let finalStorage = StorageService(databasePath: databasePath)
        raceStorages.append(finalStorage)
        try await finalStorage.open()
        let finalItemResult = try await finalStorage.findByID(inserted.id)
        let finalItem = try XCTUnwrap(finalItemResult)
        XCTAssertEqual(finalItem.sizeBytes, updatedSize)
        XCTAssertEqual(finalItem.fileSizeBytes, updatedFileSize)
        let recent = try await finalStorage.fetchRecent(limit: 1, offset: 0)
        XCTAssertEqual(recent.first?.sizeBytes, updatedSize)
        let finalTotalSize = try await finalStorage.getTotalSize()
        XCTAssertEqual(finalTotalSize, updatedSize)
    }

    func testLargePayloadCASAndBatchSizeReconciliationRemainExactAndRejectStaleSnapshots() async throws {
        let repository = storage.repository
        let id = UUID()
        let storageRef = "/tmp/scopy-large-size-\(UUID().uuidString).bin"
        let initialHash = "large-initial-\(UUID().uuidString)"
        let initialSize = Int(Int32.max) + 4_096
        let now = Date()

        try await repository.insertItem(
            id: id,
            type: .image,
            contentHash: initialHash,
            plainText: "synthetic large payload",
            note: nil,
            appBundleID: "com.test.large-payload",
            createdAt: now,
            lastUsedAt: now,
            sizeBytes: initialSize,
            fileSizeBytes: nil,
            storageRef: storageRef,
            rawData: nil
        )
        let initialResult = try await repository.fetchItemByID(id)
        let initial = try XCTUnwrap(initialResult)

        let casHash = "large-cas-\(UUID().uuidString)"
        let casSize = initialSize + 8_192
        let casResult = try await repository.compareAndSwapItemPayload(
            expected: initial,
            contentHash: casHash,
            sizeBytes: casSize,
            storageRef: storageRef,
            rawData: nil
        )
        let casItem = try XCTUnwrap(casResult)
        XCTAssertEqual(casItem.sizeBytes, casSize)

        let staleCAS = try await repository.compareAndSwapItemPayload(
            expected: initial,
            contentHash: "must-not-commit",
            sizeBytes: casSize + 1,
            storageRef: storageRef,
            rawData: nil
        )
        XCTAssertNil(staleCAS)

        let batchSize = casSize + 16_384
        let batchUpdate = SQLiteClipboardRepository.SizeBytesUpdate(
            id: id,
            expectedContentHash: casHash,
            expectedSizeBytes: casSize,
            expectedStorageRef: storageRef,
            sizeBytes: batchSize
        )
        let updatedCount = try await repository.updateItemSizeBytesBatchInTransaction(
            updates: [batchUpdate]
        )
        XCTAssertEqual(updatedCount, 1)
        let staleUpdatedCount = try await repository.updateItemSizeBytesBatchInTransaction(
            updates: [batchUpdate]
        )
        XCTAssertEqual(staleUpdatedCount, 0, "A stale expected large size must not overwrite the committed value")

        let persistedResult = try await repository.fetchItemByID(id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.contentHash, casHash)
        XCTAssertEqual(persisted.sizeBytes, batchSize)
        let totalSize = try await repository.getTotalSize()
        XCTAssertEqual(totalSize, batchSize)
    }

    func testCleanupPlannerStopsAfterRawInjectedLargeRowSatisfiesTarget() async throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-large-cleanup-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("clipboard.db").path

        let bootstrapRepository = SQLiteClipboardRepository(dbPath: databasePath)
        try await bootstrapRepository.open()
        await bootstrapRepository.close()

        let largeID = UUID()
        let smallID = UUID()
        let largeSize = Int64(Int32.max) + 1
        let smallSize: Int64 = 64
        let rawConnection = try SQLiteConnection(
            path: databasePath,
            flags: SQLiteConnection.openFlags(for: databasePath, readOnly: false)
        )
        do {
            let insert = try rawConnection.prepare(
                """
                INSERT INTO clipboard_items
                (id, type, content_hash, plain_text, created_at, last_used_at,
                 use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes)
                VALUES (?, ?, ?, ?, ?, ?, 1, 0, ?, NULL, NULL, NULL)
                """
            )

            func insertRow(id: UUID, hash: String, lastUsedAt: Double, sizeBytes: Int64) throws {
                insert.reset()
                try insert.bindText(id.uuidString, at: 1)
                try insert.bindText(ClipboardItemType.text.rawValue, at: 2)
                try insert.bindText(hash, at: 3)
                try insert.bindText(hash, at: 4)
                try insert.bindDouble(lastUsedAt, at: 5)
                try insert.bindDouble(lastUsedAt, at: 6)
                try insert.bindInt64(sizeBytes, at: 7)
                XCTAssertFalse(try insert.step())
            }

            try insertRow(id: largeID, hash: "raw-large", lastUsedAt: 1, sizeBytes: largeSize)
            try insertRow(id: smallID, hash: "raw-small", lastUsedAt: 2, sizeBytes: smallSize)
        } catch {
            rawConnection.close()
            throw error
        }
        rawConnection.close()

        let repository = SQLiteClipboardRepository(dbPath: databasePath)
        do {
            try await repository.open()
            let totalSize = try await repository.getTotalSize()
            let plan = try await repository.planCleanupByTotalSize(targetBytes: Int(smallSize))
            await repository.close()

            XCTAssertEqual(totalSize, Int(largeSize + smallSize))
            XCTAssertEqual(plan.ids, [largeID])
            XCTAssertFalse(plan.ids.contains(smallID))
        } catch {
            await repository.close()
            throw error
        }
    }

    func testCleanupPlannerCanReachTargetBeyondTenThousandRows() async throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-cleanup-over-ten-thousand")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("clipboard.db").path

        let bootstrapRepository = SQLiteClipboardRepository(dbPath: databasePath)
        try await bootstrapRepository.open()
        await bootstrapRepository.close()

        let rowCount = 10_001
        let rawConnection = try SQLiteConnection(
            path: databasePath,
            flags: SQLiteConnection.openFlags(for: databasePath, readOnly: false)
        )
        do {
            try rawConnection.execute("BEGIN IMMEDIATE TRANSACTION")
            let insert = try rawConnection.prepare(
                """
                INSERT INTO clipboard_items
                (id, type, content_hash, plain_text, created_at, last_used_at,
                 use_count, is_pinned, size_bytes, storage_ref, raw_data, file_size_bytes)
                VALUES (?, ?, ?, ?, ?, ?, 1, 0, 1, NULL, NULL, NULL)
                """
            )
            for index in 0..<rowCount {
                let id = UUID()
                let hash = "cleanup-over-ten-thousand-\(index)"
                insert.reset()
                try insert.bindText(id.uuidString, at: 1)
                try insert.bindText(ClipboardItemType.text.rawValue, at: 2)
                try insert.bindText(hash, at: 3)
                try insert.bindText(hash, at: 4)
                try insert.bindDouble(Double(index), at: 5)
                try insert.bindDouble(Double(index), at: 6)
                _ = try insert.step()
            }
            try rawConnection.execute("COMMIT")
        } catch {
            try? rawConnection.execute("ROLLBACK")
            rawConnection.close()
            throw error
        }
        rawConnection.close()

        let repository = SQLiteClipboardRepository(dbPath: databasePath)
        do {
            try await repository.open()
            let plan = try await repository.planCleanupByTotalSize(targetBytes: 0)
            await repository.close()

            XCTAssertEqual(plan.ids.count, rowCount)
            XCTAssertEqual(plan.candidates.reduce(0) { $0 + $1.sizeBytes }, rowCount)
        } catch {
            await repository.close()
            throw error
        }
    }

    func testSparseFiveGiBFileMetadataAndCheckedAggregation() throws {
        let directory = try makeTemporaryDirectory(prefix: "scopy-sparse-file")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("five-gib.dat")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let fiveGiB = 5 * 1024 * 1024 * 1024
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(fiveGiB))
        }

        XCTAssertEqual(FilePreviewSupport.totalFileSizeBytes(from: fileURL.path), fiveGiB)
        XCTAssertEqual(FilePreviewSupport.checkedTotalFileSizeBytes([fiveGiB, 1]), fiveGiB + 1)
        XCTAssertNil(FilePreviewSupport.checkedTotalFileSizeBytes([Int.max, 1]))
    }

    // MARK: - Cleanup Tests (v0.md 2.3)

    func testOptimizationStageCleanupPreservesRecentAndReclaimsOnlyStaleStages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-stage-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let recentStage = directory.appendingPathComponent(".scopy-optimize-recent.stage")
        let staleStage = directory.appendingPathComponent(".scopy-optimize-stale.stage")
        let unrelatedHiddenFile = directory.appendingPathComponent(".unrelated.stage")
        try Data([1]).write(to: recentStage)
        try Data([2]).write(to: staleStage)
        try Data([3]).write(to: unrelatedHiddenFile)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: recentStage.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(25 * 60 * 60))],
            ofItemAtPath: staleStage.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(25 * 60 * 60))],
            ofItemAtPath: unrelatedHiddenFile.path
        )

        let stale = StorageService.staleImageOptimizationStageFiles(
            externalStoragePath: directory.path,
            now: now,
            maximumAge: 24 * 60 * 60
        )

        let resolvedStale = Set(stale.map { $0.resolvingSymlinksInPath() })
        XCTAssertEqual(resolvedStale, [staleStage.resolvingSymlinksInPath()])
        XCTAssertFalse(resolvedStale.contains(recentStage.resolvingSymlinksInPath()))
        XCTAssertFalse(resolvedStale.contains(unrelatedHiddenFile.resolvingSymlinksInPath()))
    }

    func testCleanupByCount() async throws {
        storage.cleanupSettings.maxItems = 5

        // Insert 10 items
        for i in 0..<10 {
            let content = makeTestContent(text: "Item \(i)")
            _ = try await storage.upsertItem(content)
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms for ordering
        }

        let countBeforeCleanup = try await storage.getItemCount()
        XCTAssertEqual(countBeforeCleanup, 10)

        // Cleanup
        try await storage.performCleanup()

        // Should have max 5 items
        let countAfterCleanup = try await storage.getItemCount()
        XCTAssertLessThanOrEqual(countAfterCleanup, 5)
    }

    func testCleanupCommitSkipsCandidatePinnedAfterPlanning() async throws {
        let directory = try makeTemporaryDirectory(prefix: "cleanup-pin-revalidation")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let probe = RemoveFileProbe()
        let primary = StorageService(
            databasePath: databasePath,
            fileOps: makeRecordingFileOps(probe)
        )
        let competing = StorageService(databasePath: databasePath)
        try await primary.open()
        try await competing.open()
        raceStorages.append(primary)
        raceStorages.append(competing)
        raceStorageDirectories.append(directory)

        let candidate = try await primary.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await primary.upsertItem(makeLargeTestContent())
        let candidateRef = try XCTUnwrap(candidate.storageRef)

        primary.cleanupSettings.maxItems = 1
        primary.cleanupSettings.maxSmallStorageMB = 200
        primary.cleanupSettings.maxLargeStorageMB = 800
        let gate = StorageMetadataUpdateGate()
        primary.setCleanupInterlockForTesting { point in
            guard case .afterPlanBeforeCommit(let itemIDs) = point,
                  itemIDs.contains(candidate.id) else { return }
            await gate.pause()
        }

        let cleanup = Task { try await primary.performCleanup(mode: .light) }
        await gate.waitUntilPaused()
        try await competing.setPin(candidate.id, pinned: true)
        await gate.release()
        let result = try await cleanup.value

        let persistedResult = try await primary.findByID(candidate.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertTrue(persisted.isPinned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateRef))
        XCTAssertEqual(result.plannedItemCount, 1)
        XCTAssertEqual(result.deletedItemIDs, [])
        XCTAssertEqual(result.skippedItemCount, 1)
        XCTAssertEqual(probe.callCount, 0)
    }

    func testCleanupCommitSkipsCandidateWhosePayloadWasReplacedAfterPlanning() async throws {
        let directory = try makeTemporaryDirectory(prefix: "cleanup-payload-revalidation")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let probe = RemoveFileProbe()
        let primary = StorageService(
            databasePath: databasePath,
            fileOps: makeRecordingFileOps(probe)
        )
        let competing = StorageService(databasePath: databasePath)
        try await primary.open()
        try await competing.open()
        raceStorages.append(primary)
        raceStorages.append(competing)
        raceStorageDirectories.append(directory)

        let candidate = try await primary.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await primary.upsertItem(makeLargeTestContent())
        let oldRef = try XCTUnwrap(candidate.storageRef)

        primary.cleanupSettings.maxItems = 1
        primary.cleanupSettings.maxSmallStorageMB = 200
        primary.cleanupSettings.maxLargeStorageMB = 800
        let gate = StorageMetadataUpdateGate()
        primary.setCleanupInterlockForTesting { point in
            guard case .afterPlanBeforeCommit(let itemIDs) = point,
                  itemIDs.contains(candidate.id) else { return }
            await gate.pause()
        }

        let cleanup = Task { try await primary.performCleanup(mode: .light) }
        await gate.waitUntilPaused()

        let replacementData = Data(repeating: 0x3C, count: 256 * 1024)
        let stageURL = URL(fileURLWithPath: oldRef)
            .deletingLastPathComponent()
            .appendingPathComponent(".scopy-cleanup-payload-race.stage")
        try replacementData.write(to: stageURL, options: .atomic)
        let replacementHash = "cleanup-replacement-\(UUID().uuidString)"
        let replacedResult = try await competing.commitOptimizedExternalImagePayload(
            expected: candidate,
            stagedURL: stageURL,
            contentHash: replacementHash,
            sizeBytes: replacementData.count
        )
        let replaced = try XCTUnwrap(replacedResult)
        await gate.release()
        let result = try await cleanup.value

        let persistedResult = try await primary.findByID(candidate.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.contentHash, replacementHash)
        XCTAssertEqual(persisted.storageRef, replaced.storageRef)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(replaced.storageRef)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRef))
        XCTAssertEqual(result.plannedItemCount, 1)
        XCTAssertEqual(result.deletedItemIDs, [])
        XCTAssertEqual(result.skippedItemCount, 1)
        XCTAssertEqual(probe.callCount, 0)
    }

    func testCleanupReportsEarlierCommittedBatchBeforeLaterPhaseFails() async throws {
        let directory = try makeTemporaryDirectory(prefix: "cleanup-partial-result")
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let diskStorage = StorageService(databasePath: databasePath)
        try await diskStorage.open()
        raceStorages.append(diskStorage)
        raceStorageDirectories.append(directory)

        let oldest = try await diskStorage.upsertItem(makeTestContent(text: "oldest"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await diskStorage.upsertItem(makeTestContent(text: "middle"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await diskStorage.upsertItem(makeTestContent(text: "newest"))

        diskStorage.cleanupSettings.maxItems = 2
        diskStorage.cleanupSettings.maxDaysAge = 0
        diskStorage.cleanupSettings.maxSmallStorageMB = 200
        diskStorage.cleanupSettings.maxLargeStorageMB = 800

        let probe = CleanupFailureProbe()
        do {
            _ = try await diskStorage.performCleanup(
                mode: .light,
                onCommitted: { result in
                    await probe.recordAndInstallFailure(after: result, dbPath: databasePath)
                }
            )
            XCTFail("Expected the injected later cleanup phase to fail")
        } catch {
            // The first count phase is already committed and must already have been reported.
        }

        let snapshot = await probe.snapshot()
        XCTAssertNil(snapshot.triggerError)
        XCTAssertEqual(snapshot.batches, [[oldest.id]])
        let deletedItem = try await diskStorage.findByID(oldest.id)
        let remainingCount = try await diskStorage.getItemCount()
        XCTAssertNil(deletedItem)
        XCTAssertEqual(remainingCount, 2)
    }

    func testCleanupDoesNotUnlinkCommittedRefStillOwnedBySurvivingRow() async throws {
        let probe = RemoveFileProbe()
        let (diskStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "cleanup-shared-ref",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await diskStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        let oldest = try await diskStorage.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        let survivor = try await diskStorage.upsertItem(makeLargeTestContent())
        let sharedRef = try XCTUnwrap(oldest.storageRef)
        try await diskStorage.updateItemPayload(
            id: survivor.id,
            contentHash: "shared-ref-survivor-\(UUID().uuidString)",
            sizeBytes: survivor.sizeBytes,
            storageRef: sharedRef,
            rawData: nil
        )

        diskStorage.cleanupSettings.maxItems = 1
        diskStorage.cleanupSettings.maxSmallStorageMB = 200
        diskStorage.cleanupSettings.maxLargeStorageMB = 800
        let result = try await diskStorage.performCleanup(mode: .light)

        XCTAssertEqual(result.deletedItemIDs, [oldest.id])
        XCTAssertEqual(result.fileDeletionCandidateCount, 1)
        XCTAssertEqual(result.fileDeletionAttemptCount, 0)
        XCTAssertEqual(result.fileCleanupFailureCount, 0)
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedRef))
        let persistedSurvivor = try await diskStorage.findByID(survivor.id)
        XCTAssertEqual(persistedSurvivor?.storageRef, sharedRef)
    }

    func testCleanupPreservesPinned() async throws {
        storage.cleanupSettings.maxItems = 3

        // Insert 5 items
        for i in 0..<5 {
            let content = makeTestContent(text: "Item \(i)")
            _ = try await storage.upsertItem(content)
        }

        // Pin 2 items
        let items = try await storage.fetchRecent(limit: 10, offset: 0)
        try await storage.setPin(items[0].id, pinned: true)
        try await storage.setPin(items[1].id, pinned: true)

        // Cleanup
        try await storage.performCleanup()

        // All pinned items should survive
        let remaining = try await storage.fetchRecent(limit: 10, offset: 0)
        let pinnedCount = remaining.filter { $0.isPinned }.count
        XCTAssertEqual(pinnedCount, 2)
    }

    func testCleanupImagesOnlyBySizeDoesNotDeleteText() async throws {
        storage.cleanupSettings.cleanupImagesOnly = true
        storage.cleanupSettings.maxSmallStorageMB = 1

        // Insert text first (oldest)
        for i in 0..<5 {
            let content = makeTestContent(text: "Text \(i)")
            _ = try await storage.upsertItem(content)
        }

        // Insert large images to exceed size limit
        let image1 = try await storage.upsertItem(makeLargeTestContent())
        let image2 = try await storage.upsertItem(makeLargeTestContent())
        let countBeforeCleanup = try await storage.getItemCount()
        XCTAssertEqual(countBeforeCleanup, 7)

        // Cleanup should delete images but keep all text items.
        try await storage.performCleanup()

        let remaining = try await storage.fetchRecent(limit: 100, offset: 0)
        XCTAssertEqual(remaining.filter { $0.type == .text }.count, 5)
        XCTAssertTrue(remaining.allSatisfy { $0.type == .text })
        let foundImage1 = try await storage.findByID(image1.id)
        XCTAssertNil(foundImage1)
        let foundImage2 = try await storage.findByID(image2.id)
        XCTAssertNil(foundImage2)
    }

    func testCleanupImagesOnlyByCountDoesNotDeleteText() async throws {
        storage.cleanupSettings.cleanupImagesOnly = true
        storage.cleanupSettings.maxItems = 3

        // Insert texts
        for i in 0..<5 {
            let content = makeTestContent(text: "Text \(i)")
            _ = try await storage.upsertItem(content)
        }

        // Insert images (eligible for cleanup)
        let image1 = try await storage.upsertItem(makeLargeTestContent())
        let image2 = try await storage.upsertItem(makeLargeTestContent())
        let countBeforeCleanup = try await storage.getItemCount()
        XCTAssertEqual(countBeforeCleanup, 7)

        // Cleanup should delete images but not text, even if still above maxItems.
        try await storage.performCleanup()

        let remaining = try await storage.fetchRecent(limit: 100, offset: 0)
        XCTAssertEqual(remaining.filter { $0.type == .text }.count, 5)
        XCTAssertTrue(remaining.allSatisfy { $0.type == .text })
        let foundImage1 = try await storage.findByID(image1.id)
        XCTAssertNil(foundImage1)
        let foundImage2 = try await storage.findByID(image2.id)
        XCTAssertNil(foundImage2)
        let countAfterCleanup = try await storage.getItemCount()
        XCTAssertEqual(countAfterCleanup, 5)
    }

    func testCleanupByCountDeletesExternalFilesThroughDeletePlanExecutor() async throws {
        let probe = RemoveFileProbe()
        let (routedStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "scopy-cleanup-count-route",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await routedStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        routedStorage.cleanupSettings.maxItems = 1
        routedStorage.cleanupSettings.maxSmallStorageMB = 200
        routedStorage.cleanupSettings.maxLargeStorageMB = 800

        _ = try await routedStorage.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await routedStorage.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await routedStorage.upsertItem(makeLargeTestContent())

        try await routedStorage.performCleanup(mode: .light)

        let remaining = try await routedStorage.fetchRecent(limit: 10, offset: 0)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testCleanupImagesOnlyByCountDeletesExternalFilesThroughDeletePlanExecutor() async throws {
        let probe = RemoveFileProbe()
        let (routedStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "scopy-cleanup-images-count-route",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await routedStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        routedStorage.cleanupSettings.cleanupImagesOnly = true
        routedStorage.cleanupSettings.maxItems = 1
        routedStorage.cleanupSettings.maxSmallStorageMB = 200
        routedStorage.cleanupSettings.maxLargeStorageMB = 800

        let text = try await routedStorage.upsertItem(makeTestContent(text: "text survives"))
        let image1 = try await routedStorage.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        let image2 = try await routedStorage.upsertItem(makeLargeTestContent())

        try await routedStorage.performCleanup(mode: .light)

        let survivingText = try await routedStorage.findByID(text.id)
        let removedImage1 = try await routedStorage.findByID(image1.id)
        let removedImage2 = try await routedStorage.findByID(image2.id)
        XCTAssertNotNil(survivingText)
        XCTAssertNil(removedImage1)
        XCTAssertNil(removedImage2)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testCleanupByAgeDeletesExternalFilesThroughDeletePlanExecutor() async throws {
        let probe = RemoveFileProbe()
        let (routedStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "scopy-cleanup-age-route",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await routedStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        routedStorage.cleanupSettings.maxItems = 10
        routedStorage.cleanupSettings.maxDaysAge = 0
        routedStorage.cleanupSettings.maxSmallStorageMB = 200
        routedStorage.cleanupSettings.maxLargeStorageMB = 800

        let item = try await routedStorage.upsertItem(makeLargeTestContent())

        try await routedStorage.performCleanup(mode: .light)

        let missing = try await routedStorage.findByID(item.id)
        XCTAssertNil(missing)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testCleanupBySizeDeletesExternalFilesThroughDeletePlanExecutor() async throws {
        let probe = RemoveFileProbe()
        let (routedStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "scopy-cleanup-size-route",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await routedStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        routedStorage.cleanupSettings.maxItems = 10
        routedStorage.cleanupSettings.maxSmallStorageMB = 1
        routedStorage.cleanupSettings.maxLargeStorageMB = 800

        let first = try await routedStorage.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = try await routedStorage.upsertItem(makeLargeTestContent())

        try await routedStorage.performCleanup(mode: .light)

        let removedFirst = try await routedStorage.findByID(first.id)
        let removedSecond = try await routedStorage.findByID(second.id)
        XCTAssertNil(removedFirst)
        XCTAssertNil(removedSecond)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testCleanupExternalStorageDeletesExternalFilesThroughDeletePlanExecutor() async throws {
        let probe = RemoveFileProbe()
        let (routedStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "scopy-cleanup-external-route",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await routedStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        routedStorage.cleanupSettings.maxItems = 10
        routedStorage.cleanupSettings.maxSmallStorageMB = 200
        routedStorage.cleanupSettings.maxLargeStorageMB = 0

        let item = try await routedStorage.upsertItem(makeLargeTestContent())

        try await routedStorage.performCleanup(mode: .light)

        let missing = try await routedStorage.findByID(item.id)
        XCTAssertNil(missing)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testCleanupSkipsInvalidStorageRefAfterDBDelete() async throws {
        let probe = RemoveFileProbe()
        let (routedStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "scopy-cleanup-invalid-ref",
            fileOps: makeRecordingFileOps(probe)
        )
        defer {
            Task { @MainActor in
                await routedStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        let invalidDirectory = baseURL.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let invalidRef = invalidDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x01, 0x02, 0x03]).write(to: invalidRef)

        let item = try await routedStorage.upsertItem(makeLargeTestContent())
        try await routedStorage.updateItemPayload(
            id: item.id,
            contentHash: "invalid-ref-\(UUID().uuidString)",
            sizeBytes: item.sizeBytes,
            storageRef: invalidRef.path,
            rawData: nil
        )

        routedStorage.cleanupSettings.maxItems = 0
        routedStorage.cleanupSettings.maxSmallStorageMB = 200
        routedStorage.cleanupSettings.maxLargeStorageMB = 800

        try await routedStorage.performCleanup(mode: .light)

        let missing = try await routedStorage.findByID(item.id)
        XCTAssertNil(missing)
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidRef.path))
    }

    func testExternalStorageIsIsolatedFromUserDataDuringTests() async throws {
        let content = makeLargeTestContent()
        let item = try await storage.upsertItem(content)

        guard let storageRef = item.storageRef else {
            XCTFail("Expected external storageRef for large content")
            return
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertFalse(
            storageRef.contains(appSupport.path),
            "Tests should not write into Application Support: \(storageRef)"
        )

        XCTAssertTrue(
            storageRef.hasPrefix(FileManager.default.temporaryDirectory.path),
            "Expected test external storage to live under temporaryDirectory: \(storageRef)"
        )

        try await storage.deleteItem(item.id)
    }

    func testDiskDatabaseUsesDatabaseDirectoryForExternalStorageInTests() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let diskStorage = StorageService(databasePath: dbPath)
        try await diskStorage.open()

        let content = makeLargeTestContent()
        let item = try await diskStorage.upsertItem(content)
        guard let storageRef = item.storageRef else {
            XCTFail("Expected external storageRef for large content")
            return
        }

        let expectedPrefix = baseURL.appendingPathComponent("content", isDirectory: true).path
        XCTAssertTrue(
            storageRef.hasPrefix(expectedPrefix),
            "Expected external storage to be colocated with database: \(storageRef)"
        )

        try await diskStorage.deleteItem(item.id)
        await diskStorage.close()
        try? FileManager.default.removeItem(at: baseURL)
    }

    func testDeleteItemDoesNotRemoveExternalFileWhenDBIsBusy() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-delete-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let probe = RemoveFileProbe()
        let fileOps = StorageService.StorageFileOps(removeFile: { url in
            probe.recordCall()
            try FileManager.default.removeItem(at: url)
        })

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let diskStorage = StorageService(databasePath: dbPath, fileOps: fileOps)
        try await diskStorage.open()
        defer {
            Task { @MainActor in
                await diskStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        let item = try await diskStorage.upsertItem(makeLargeTestContent())
        guard let storageRef = item.storageRef else {
            XCTFail("Expected external storageRef for large content")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRef))

        let lockFlags = SQLiteConnection.openFlags(for: dbPath, readOnly: false)
        let locker = try SQLiteConnection(path: dbPath, flags: lockFlags)
        try locker.execute("BEGIN IMMEDIATE TRANSACTION")
        defer {
            try? locker.execute("ROLLBACK")
            locker.close()
        }

        do {
            try await diskStorage.deleteItem(item.id)
            XCTFail("Expected deleteItem to fail while DB is busy")
        } catch {
            // Expected
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storageRef),
            "File should not be deleted when DB deletion fails"
        )
        XCTAssertEqual(probe.callCount, 0, "File remover should not be called when DB deletion fails")
    }

    func testCleanupByCountDoesNotRemoveExternalFilesWhenDBIsBusy() async throws {
        let baseURL = try makeTemporaryDirectory(prefix: "scopy-cleanup-busy")

        let probe = RemoveFileProbe()
        let fileOps = makeRecordingFileOps(probe)

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let diskStorage = StorageService(databasePath: dbPath, fileOps: fileOps)
        try await diskStorage.open()
        defer {
            Task { @MainActor in
                await diskStorage.close()
                try? FileManager.default.removeItem(at: baseURL)
            }
        }

        let first = try await diskStorage.upsertItem(makeLargeTestContent())
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = try await diskStorage.upsertItem(makeLargeTestContent())

        guard let firstStorageRef = first.storageRef,
              let secondStorageRef = second.storageRef else {
            XCTFail("Expected external storageRefs for large content")
            return
        }

        diskStorage.cleanupSettings.maxItems = 1
        diskStorage.cleanupSettings.maxSmallStorageMB = 200
        diskStorage.cleanupSettings.maxLargeStorageMB = 800

        do {
            let lockFlags = SQLiteConnection.openFlags(for: dbPath, readOnly: false)
            let locker = try SQLiteConnection(path: dbPath, flags: lockFlags)
            try locker.execute("BEGIN IMMEDIATE TRANSACTION")
            defer {
                try? locker.execute("ROLLBACK")
                locker.close()
            }

            do {
                try await diskStorage.performCleanup(mode: .light)
                XCTFail("Expected cleanup to fail while DB is busy")
            } catch {
                // Expected
            }
        }

        XCTAssertEqual(probe.callCount, 0, "File remover should not be called when cleanup DB deletion fails")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStorageRef))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStorageRef))
        let countAfterFailedCleanup = try await diskStorage.getItemCount()
        XCTAssertEqual(countAfterFailedCleanup, 2)
    }

    func testSyncExternalImageSizeBytesFromDiskUpdatesDBSizeBytes() async throws {
        let item = try await storage.upsertItem(makeLargeTestContent())

        guard let storageRef = item.storageRef else {
            XCTFail("Expected external storageRef for image item")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRef))

        let smallerData = Data(repeating: 0x00, count: 1234)
        try smallerData.write(to: URL(fileURLWithPath: storageRef), options: [.atomic])

        let updated = try await storage.syncExternalImageSizeBytesFromDisk()
        XCTAssertEqual(updated, 1)

        let refreshed = try await storage.findByID(item.id)
        XCTAssertEqual(refreshed?.sizeBytes, smallerData.count)
    }

    func testSyncExternalImageSizeRejectsStaleStatAfterPayloadCAS() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(prefix: "size-sync-cas-race")
        let item = try await primary.upsertItem(makeLargeTestContent())
        let oldURL = URL(fileURLWithPath: try XCTUnwrap(item.storageRef))
        let staleStatData = Data(repeating: 0x31, count: 1_111)
        try staleStatData.write(to: oldURL, options: .atomic)

        let gate = StorageMetadataUpdateGate()
        primary.setExternalSizeSyncInterlockForTesting { point in
            guard case .afterStatBeforeCommit = point else { return }
            await gate.pause()
        }
        let sync = Task { try await primary.syncExternalImageSizeBytesFromDisk() }
        await gate.waitUntilPaused()

        let optimizedData = Data(repeating: 0x52, count: 777)
        let stagedURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(".scopy-size-sync-test.stage")
        try optimizedData.write(to: stagedURL, options: .atomic)
        let optimizedHash = "optimized-\(UUID().uuidString)"
        let committed: StorageService.StoredItem?
        do {
            committed = try await competing.commitOptimizedExternalImagePayload(
                expected: item,
                stagedURL: stagedURL,
                contentHash: optimizedHash,
                sizeBytes: optimizedData.count
            )
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()

        XCTAssertNotNil(committed)
        let updatedCount = try await sync.value
        XCTAssertEqual(updatedCount, 0)
        let persistedResult = try await primary.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.contentHash, optimizedHash)
        XCTAssertEqual(persisted.sizeBytes, optimizedData.count)
        XCTAssertEqual(persisted.storageRef, committed?.storageRef)
        XCTAssertNotEqual(persisted.storageRef, oldURL.path)
    }

    func testOrphanCleanupAbortsWhenOldSourceIsRestoredAfterSnapshot() async throws {
        let (diskStorage, baseURL) = try await makeTemporaryStorage(
            prefix: "cleanup-restore-race",
            fileOps: .live
        )
        raceStorages.append(diskStorage)
        raceStorageDirectories.append(baseURL)
        let item = try await diskStorage.upsertItem(makeLargeTestContent())
        let oldURL = URL(fileURLWithPath: try XCTUnwrap(item.storageRef))
        let oldData = try Data(contentsOf: oldURL)

        let stagedURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(".scopy-cleanup-restore-test.stage")
        let optimizedData = Data(repeating: 0x63, count: 512)
        try optimizedData.write(to: stagedURL, options: .atomic)
        let optimizedResult = try await diskStorage.commitOptimizedExternalImagePayload(
            expected: item,
            stagedURL: stagedURL,
            contentHash: "cleanup-optimized-\(UUID().uuidString)",
            sizeBytes: optimizedData.count
        )
        let optimized = try XCTUnwrap(optimizedResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))

        let gate = StorageMetadataUpdateGate()
        diskStorage.setOrphanCleanupInterlockForTesting { point in
            guard case .afterEnumerationBeforeOwnershipValidation = point else { return }
            await gate.pause()
        }
        let cleanup = Task { try await diskStorage.cleanupOrphanedFiles() }
        await gate.waitUntilPaused()

        let restored: StorageService.ExternalSourceReconciliationResult? = await diskStorage.withExternalImageSourceLease(sourceURL: oldURL) { lease in
            await diskStorage.reconcileExternalImageSourceOwnership(
                committedItem: optimized,
                sourceURL: oldURL,
                sourceLease: lease
            )
        }
        await gate.release()
        try await cleanup.value

        XCTAssertEqual(restored, StorageService.ExternalSourceReconciliationResult.adopted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: oldURL), oldData)
        let persistedResult = try await diskStorage.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.storageRef, oldURL.path)
    }

    func testOrphanCleanupReservationSerializesReconcileAfterDeleteGuard() async throws {
        let (diskStorage, competingStorage) = try await makeCompetingDiskStorages(
            prefix: "cleanup-remove-reservation"
        )
        let item = try await diskStorage.upsertItem(makeLargeTestContent())
        let oldURL = URL(fileURLWithPath: try XCTUnwrap(item.storageRef))
        let oldReservationKey = oldURL.resolvingSymlinksInPath().standardizedFileURL.path
        let stagedURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(".scopy-cleanup-reservation.stage")
        let optimizedData = Data(repeating: 0x71, count: 640)
        try optimizedData.write(to: stagedURL, options: .atomic)
        let optimizedResult = try await diskStorage.commitOptimizedExternalImagePayload(
            expected: item,
            stagedURL: stagedURL,
            contentHash: "reservation-optimized-\(UUID().uuidString)",
            sizeBytes: optimizedData.count
        )
        let optimized = try XCTUnwrap(optimizedResult)

        let gate = StorageMetadataUpdateGate()
        diskStorage.setOrphanCleanupInterlockForTesting { point in
            guard case .afterOwnershipValidationBeforeRemove(let path) = point,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == oldReservationKey else { return }
            await gate.pause()
        }
        let cleanup = Task { try await diskStorage.cleanupOrphanedFiles() }
        await gate.waitUntilPaused()

        let reconcile = Task {
            await competingStorage.withExternalImageSourceLease(sourceURL: oldURL) { lease in
                await competingStorage.reconcileExternalImageSourceOwnership(
                    committedItem: optimized,
                    sourceURL: oldURL,
                    sourceLease: lease
                )
            }
        }
        await Task.yield()
        await gate.release()
        try await cleanup.value
        let reconciliation: StorageService.ExternalSourceReconciliationResult? = await reconcile.value

        XCTAssertEqual(
            reconciliation,
            StorageService.ExternalSourceReconciliationResult.sourceUnavailable
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        let persistedResult = try await diskStorage.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.storageRef, optimized.storageRef)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(persisted.storageRef)))
    }

    func testReconciliationRepairsAfterConcurrentExternalSizeUpdateThenAdoptsStableSource() async throws {
        let (primary, competing) = try await makeCompetingDiskStorages(
            prefix: "reconcile-size-update-race"
        )
        let item = try await primary.upsertItem(makeLargeTestContent())
        let sourceURL = URL(fileURLWithPath: try XCTUnwrap(item.storageRef))

        let stagedURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".scopy-reconcile-size-race.stage")
        let optimizedData = Data(repeating: 0x41, count: 1_024)
        try optimizedData.write(to: stagedURL, options: .atomic)
        let committedResult = try await primary.commitOptimizedExternalImagePayload(
            expected: item,
            stagedURL: stagedURL,
            contentHash: "optimized-\(UUID().uuidString)",
            sizeBytes: optimizedData.count
        )
        let committed = try XCTUnwrap(committedResult)

        let firstLiveData = Data(repeating: 0x52, count: item.sizeBytes - 257)
        let stableLiveData = Data(repeating: 0x63, count: firstLiveData.count - 257)
        try firstLiveData.write(to: sourceURL, options: .atomic)
        let sizeSyncCount = StorageIntBox()
        let reconciliation = await primary.withExternalImageSourceLease(sourceURL: sourceURL) { lease in
            await primary.reconcileExternalImageSourceOwnership(
                committedItem: committed,
                sourceURL: sourceURL,
                sourceLease: lease,
                verificationInterlock: { attempt in
                    guard attempt == 0 else { return }
                    try? stableLiveData.write(to: sourceURL, options: .atomic)
                    await sizeSyncCount.set(
                        (try? await competing.syncExternalImageSizeBytesFromDisk()) ?? -1
                    )
                }
            )
        }

        let observedSizeSyncCount = await sizeSyncCount.get()
        XCTAssertEqual(observedSizeSyncCount, 1)
        XCTAssertEqual(reconciliation, .adopted)
        let persistedResult = try await primary.findByID(item.id)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.storageRef, sourceURL.path)
        XCTAssertEqual(persisted.contentHash, ClipboardMonitor.computeHashStatic(stableLiveData))
        XCTAssertEqual(persisted.sizeBytes, stableLiveData.count)
        XCTAssertEqual(try Data(contentsOf: sourceURL), stableLiveData)
    }

    // MARK: - Helpers

    private func makeTestContent(text: String, type: ClipboardItemType = .text) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: type,
            plainText: text,
            payload: .none,
            appBundleID: "com.test.app",
            contentHash: computeHash(text),
            sizeBytes: text.utf8.count
        )
    }

    private func computeHash(_ text: String) -> String {
        // Simple hash for testing
        var hasher = Hasher()
        hasher.combine(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return String(hasher.finalize())
    }

    private func makeLargeTestContent() -> ClipboardMonitor.ClipboardContent {
        let data = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        return ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "Large test image",
            payload: .data(data),
            appBundleID: "com.test.app",
            contentHash: "large-\(UUID().uuidString)",
            sizeBytes: data.count
        )
    }

    private func makeTemporaryStorage(
        prefix: String,
        fileOps: StorageService.StorageFileOps
    ) async throws -> (StorageService, URL) {
        let baseURL = try makeTemporaryDirectory(prefix: prefix)
        let storage = StorageService(databasePath: ":memory:", storageRootURL: baseURL, fileOps: fileOps)
        try await storage.open()
        return (storage, baseURL)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    private func makeCompetingDiskStorages(
        prefix: String
    ) async throws -> (primary: StorageService, competing: StorageService) {
        let directory = try makeTemporaryDirectory(prefix: prefix)
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let primary = StorageService(databasePath: databasePath)
        let competing = StorageService(databasePath: databasePath)
        do {
            try await primary.open()
            try await competing.open()
        } catch {
            await competing.close()
            await primary.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        raceStorages.append(primary)
        raceStorages.append(competing)
        raceStorageDirectories.append(directory)
        return (primary, competing)
    }

    private func makeRecordingFileOps(_ probe: RemoveFileProbe) -> StorageService.StorageFileOps {
        StorageService.StorageFileOps(removeFile: { url in
            probe.recordCall()
            try FileManager.default.removeItem(at: url)
        })
    }
}
