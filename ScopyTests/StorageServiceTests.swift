import XCTest
#if !SCOPY_TSAN_TESTS
@testable import Scopy
#endif

/// StorageService 单元测试
/// 验证 v0.md 第2、3节的存储和去重要求
@MainActor
final class StorageServiceTests: XCTestCase {

    var storage: StorageService!

    override func setUp() async throws {
        try await super.setUp()
        // Use in-memory database for testing
        storage = StorageService(databasePath: ":memory:")
        try await storage.open()
    }

    override func tearDown() async throws {
        storage.close()
        storage = nil
        try await super.tearDown()
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
}
