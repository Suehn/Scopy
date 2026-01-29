import XCTest
@testable import ScopyKit

/// StorageService 单元测试
/// 验证 v0.md 第2、3节的存储和去重要求
@MainActor
final class StorageServiceTests: XCTestCase {

    var storage: StorageService!

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
        await storage.close()
        storage = nil
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

    // MARK: - Cleanup Tests (v0.md 2.3)

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
}
