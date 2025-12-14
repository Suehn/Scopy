import AppKit
import XCTest
import ScopyKit

/// 集成测试 - 测试完整的服务链
/// 验证 v0.md 的端到端功能
@MainActor
final class IntegrationTests: XCTestCase {

    var service: (any ClipboardServiceProtocol)!
    private var tempDirectory: URL?
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!
    private var settingsSuiteName: String?

    override func setUp() async throws {
        let suiteName = "scopy-integration-settings-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settingsStore = SettingsStore(suiteName: suiteName)
        settingsSuiteName = suiteName

        pasteboard = NSPasteboard.withUniqueName()

        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        tempDirectory = baseURL

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.1
        )
        try await service.start()
    }

    override func tearDown() async throws {
        service.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        service = nil
        tempDirectory = nil
        pasteboard = nil
        settingsStore = nil
        if let suiteName = settingsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        settingsSuiteName = nil
    }

    // MARK: - Full Workflow Tests

    func testFullWorkflow() async throws {
        // 1. Start with empty history
        var items = try await service.fetchRecent(limit: 10, offset: 0)
        XCTAssertEqual(items.count, 0)

        // 2. Simulate clipboard changes
        pasteboard.clearContents()
        pasteboard.setString("First item", forType: .string)
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 10, offset: 0)
            return items?.contains(where: { $0.plainText == "First item" }) ?? false
        }

        // 3. Verify item was captured
        items = try await service.fetchRecent(limit: 10, offset: 0)
        XCTAssertGreaterThanOrEqual(items.count, 1)
        if items.count > 0 {
            XCTAssertEqual(items[0].plainText, "First item")
        }
    }

    func testSearchIntegration() async throws {
        // Insert test data through clipboard
        for i in 0..<5 {
            pasteboard.clearContents()
            pasteboard.setString("Search test item \(i)", forType: .string)
            let expectedText = "Search test item \(i)"
            await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
                guard let service else { return false }
                let items = try? await service.fetchRecent(limit: 20, offset: 0)
                return items?.contains(where: { $0.plainText == expectedText }) ?? false
            }
        }

        // Search for items
        let request = SearchRequest(query: "Search test", mode: .fuzzy, limit: 50, offset: 0)
        let result = try await service.search(query: request)

        XCTAssertGreaterThanOrEqual(result.items.count, 1)
    }

    func testPinUnpinIntegration() async throws {
        // Add an item
        pasteboard.clearContents()
        let uniqueText = "Pin test item \(UUID())"
        pasteboard.setString(uniqueText, forType: .string)
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 20, offset: 0)
            return items?.contains(where: { $0.plainText == uniqueText }) ?? false
        }

        // Get the item
        var items = try await service.fetchRecent(limit: 10, offset: 0)
        guard let item = items.first(where: { $0.plainText == uniqueText }) else {
            XCTFail("No items found")
            return
        }

        XCTAssertFalse(item.isPinned)

        // Pin it
        try await service.pin(itemID: item.id)

        // Verify pinned
        items = try await service.fetchRecent(limit: 10, offset: 0)
        let pinnedItem = items.first { $0.id == item.id }
        XCTAssertTrue(pinnedItem?.isPinned ?? false)

        // Unpin it
        try await service.unpin(itemID: item.id)

        // Verify unpinned
        items = try await service.fetchRecent(limit: 10, offset: 0)
        let unpinnedItem = items.first { $0.id == item.id }
        XCTAssertFalse(unpinnedItem?.isPinned ?? true)
    }

    func testDeleteIntegration() async throws {
        // Add an item
        let uniqueText = "Delete test item \(UUID())"
        pasteboard.clearContents()
        pasteboard.setString(uniqueText, forType: .string)
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 50, offset: 0)
            return items?.contains(where: { $0.plainText == uniqueText }) ?? false
        }

        // Get the item
        var items = try await service.fetchRecent(limit: 10, offset: 0)
        guard let item = items.first(where: { $0.plainText == uniqueText }) else {
            XCTFail("Item not found")
            return
        }

        // Delete it
        try await service.delete(itemID: item.id)

        // Verify deleted
        items = try await service.fetchRecent(limit: 100, offset: 0)
        let deleted = items.first { $0.id == item.id }
        XCTAssertNil(deleted)
    }

    func testClearAllIntegration() async throws {
        // Add some items
        for i in 0..<3 {
            pasteboard.clearContents()
            let text = "Clear test \(i)"
            pasteboard.setString(text, forType: .string)
            await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
                guard let service else { return false }
                let items = try? await service.fetchRecent(limit: 20, offset: 0)
                return items?.contains(where: { $0.plainText == text }) ?? false
            }
        }

        // Pin one
        var items = try await service.fetchRecent(limit: 10, offset: 0)
        if let first = items.first {
            try await service.pin(itemID: first.id)
        }

        // Clear all
        try await service.clearAll()

        // Only pinned should remain
        items = try await service.fetchRecent(limit: 10, offset: 0)
        XCTAssertLessThanOrEqual(items.count, 1)
        if let remaining = items.first {
            XCTAssertTrue(remaining.isPinned)
        }
    }

    func testCopyToClipboardIntegration() async throws {
        // Add an item first
        let originalText = "Copy test \(UUID())"
        pasteboard.clearContents()
        pasteboard.setString(originalText, forType: .string)
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 20, offset: 0)
            return items?.contains(where: { $0.plainText == originalText }) ?? false
        }

        // Change clipboard to something else
        pasteboard.clearContents()
        pasteboard.setString("Different content", forType: .string)

        // Get our original item
        let items = try await service.fetchRecent(limit: 10, offset: 0)
        guard let item = items.first(where: { $0.plainText == originalText }) else {
            XCTFail("Original item not found")
            return
        }

        // Copy it back to clipboard
        try await service.copyToClipboard(itemID: item.id)

        // Verify clipboard content
        await waitForConditionAsync(timeout: 1.0, pollInterval: 0.05) { [pasteboard] in
            pasteboard?.string(forType: .string) == originalText
        }
    }

    func testCopyInlineRTF() async throws {
        let rtfString = "RTF inline \(UUID())"
        let rtfData = NSAttributedString(string: rtfString).rtf(from: NSRange(location: 0, length: rtfString.count), documentAttributes: [:])

        pasteboard.clearContents()
        if let rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
        } else {
            XCTFail("Failed to build RTF data")
            return
        }

        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 20, offset: 0)
            return items?.contains(where: { $0.type == .rtf && $0.plainText.contains(rtfString) }) ?? false
        }

        let items = try await service.fetchRecent(limit: 10, offset: 0)
        guard let item = items.first(where: { $0.type == .rtf }) else {
            XCTFail("RTF item not captured")
            return
        }

        try await service.copyToClipboard(itemID: item.id)

        await waitForConditionAsync(timeout: 1.0, pollInterval: 0.05) { [pasteboard] in
            pasteboard?.data(forType: .rtf) == rtfData
        }
    }

    // MARK: - Settings Tests

    func testSettingsIntegration() async throws {
        // Get default settings
        var settings = try await service.getSettings()
        XCTAssertEqual(settings.maxItems, SettingsDTO.default.maxItems)

        // Update settings
        settings.maxItems = 5000
        settings.saveImages = false
        try await service.updateSettings(settings)

        // Verify persisted
        let loaded = try await service.getSettings()
        XCTAssertEqual(loaded.maxItems, 5000)
        XCTAssertFalse(loaded.saveImages)
    }

    // MARK: - Statistics Tests

    func testStorageStatsIntegration() async throws {
        // Initially empty
        var stats = try await service.getStorageStats()
        XCTAssertEqual(stats.itemCount, 0)

        // Add items
        for i in 0..<3 {
            pasteboard.clearContents()
            let text = "Stats test \(i)"
            pasteboard.setString(text, forType: .string)
            await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
                guard let service else { return false }
                let items = try? await service.fetchRecent(limit: 20, offset: 0)
                return items?.contains(where: { $0.plainText == text }) ?? false
            }
        }

        // Check stats
        stats = try await service.getStorageStats()
        XCTAssertGreaterThanOrEqual(stats.itemCount, 1)
        XCTAssertGreaterThan(stats.sizeBytes, 0)
    }

    // MARK: - Event Stream Tests

    func testEventStream() async throws {
        var receivedEvents: [ClipboardEvent] = []

        let eventTask = Task {
            for await event in service.eventStream {
                receivedEvents.append(event)
                if receivedEvents.count >= 2 { break }
            }
        }

        // Trigger some events
        pasteboard.clearContents()
        pasteboard.setString("Event test \(UUID())", forType: .string)
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) {
            await MainActor.run {
                receivedEvents.contains { event in
                    if case .newItem = event { return true }
                    return false
                }
            }
        }

        let items = try await service.fetchRecent(limit: 10, offset: 0)
        if let item = items.first {
            try await service.pin(itemID: item.id)
        }

        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) {
            await MainActor.run {
                receivedEvents.contains { event in
                    if case .itemPinned = event { return true }
                    return false
                }
            }
        }
        eventTask.cancel()

        // Should have received events
        XCTAssertGreaterThanOrEqual(receivedEvents.count, 1)
    }

    // MARK: - Deduplication Integration Tests

    func testDeduplicationIntegration() async throws {
        let uniqueText = "Dedup test \(UUID())"

        // First copy
        pasteboard.clearContents()
        pasteboard.setString(uniqueText, forType: .string)
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 20, offset: 0)
            return items?.contains(where: { $0.plainText == uniqueText }) ?? false
        }
        let first = try await service.search(
            query: SearchRequest(query: uniqueText, mode: .exact, limit: 1, offset: 0)
        ).items.first
        let firstLastUsedAt = first?.lastUsedAt

        // Same content again
        pasteboard.clearContents()
        pasteboard.setString(uniqueText, forType: .string)
        if let firstLastUsedAt {
            await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
                guard let service else { return false }
                let result = try? await service.search(
                    query: SearchRequest(query: uniqueText, mode: .exact, limit: 1, offset: 0)
                )
                guard let latest = result?.items.first else { return false }
                return latest.lastUsedAt > firstLastUsedAt
            }
        }

        // Should only have one item with that text
        let request = SearchRequest(query: uniqueText, mode: .exact, limit: 50, offset: 0)
        let result = try await service.search(query: request)

        XCTAssertEqual(result.items.count, 1)
    }

    // MARK: - Pagination Integration Tests

    func testPaginationIntegration() async throws {
        // Add enough items to test pagination
        let count = 12
        for i in 0..<count {
            pasteboard.clearContents()
            let text = "Page test item \(i)"
            pasteboard.setString(text, forType: .string)
            await waitForConditionAsync(timeout: 2.0, pollInterval: 0.05) { [service] in
                guard let service else { return false }
                let items = try? await service.fetchRecent(limit: count + 5, offset: 0)
                return items?.contains(where: { $0.plainText == text }) ?? false
            }
        }

        // Fetch first page
        let page1 = try await service.fetchRecent(limit: 5, offset: 0)
        XCTAssertEqual(page1.count, 5)

        // Fetch second page
        let page2 = try await service.fetchRecent(limit: 5, offset: 5)
        XCTAssertEqual(page2.count, 5)

        // Pages should be different
        let ids1 = Set(page1.map { $0.id })
        let ids2 = Set(page2.map { $0.id })
        XCTAssertTrue(ids1.isDisjoint(with: ids2))
    }
}
