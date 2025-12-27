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
        await service.stopAndWait()
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

@MainActor
final class PollingIntervalSettingTests: XCTestCase {

    private var service: (any ClipboardServiceProtocol)!
    private var tempDirectory: URL?
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!
    private var settingsSuiteName: String?

    override func setUp() async throws {
        let suiteName = "scopy-polling-interval-settings-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settingsStore = SettingsStore(suiteName: suiteName)
        settingsSuiteName = suiteName

        var settings = await settingsStore.load()
        settings.clipboardPollingIntervalMs = 2000
        await settingsStore.save(settings)

        pasteboard = NSPasteboard.withUniqueName()

        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-polling-interval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        tempDirectory = baseURL

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: nil
        )
        try await service.start()
    }

    override func tearDown() async throws {
        if let service {
            await service.stopAndWait()
        }
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

    func testPollingInterval2000msDelaysCapture() async throws {
        pasteboard.clearContents()
        pasteboard.setString("Delayed capture item", forType: .string)

        try await Task.sleep(nanoseconds: 700_000_000) // 0.7s < 2.0s
        let earlyItems = try await service.fetchRecent(limit: 10, offset: 0)
        XCTAssertFalse(earlyItems.contains(where: { $0.plainText == "Delayed capture item" }))

        await waitForConditionAsync(timeout: 4.0, pollInterval: 0.05) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 20, offset: 0)
            return items?.contains(where: { $0.plainText == "Delayed capture item" }) ?? false
        }
    }
}

final class SettingsStorePersistenceTests: XCTestCase {

    func testDefaultSettingsIncludesPollingInterval() {
        XCTAssertEqual(SettingsDTO.default.clipboardPollingIntervalMs, 500)
    }

    func testDefaultSettingsIncludesPngquantExportEnabled() {
        XCTAssertTrue(SettingsDTO.default.pngquantMarkdownExportEnabled)
    }

    func testSaveAndLoadPollingIntervalPersists() async {
        let suiteName = "scopy-settingsstore-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        let store = SettingsStore(suiteName: suiteName)

        var settings = await store.load()
        settings.clipboardPollingIntervalMs = 1200
        await store.save(settings)

        let loaded = await store.load()
        XCTAssertEqual(loaded.clipboardPollingIntervalMs, 1200)
    }

    func testSaveAndLoadPngquantSettingsPersist() async {
        let suiteName = "scopy-settingsstore-pngquant-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        let store = SettingsStore(suiteName: suiteName)

        var settings = await store.load()
        settings.pngquantBinaryPath = "/tmp/pngquant"
        settings.pngquantMarkdownExportEnabled = false
        settings.pngquantMarkdownExportQualityMin = 60
        settings.pngquantMarkdownExportQualityMax = 75
        settings.pngquantMarkdownExportSpeed = 11
        settings.pngquantMarkdownExportColors = 128
        settings.pngquantCopyImageEnabled = true
        settings.pngquantCopyImageQualityMin = 55
        settings.pngquantCopyImageQualityMax = 70
        settings.pngquantCopyImageSpeed = 1
        settings.pngquantCopyImageColors = 64
        await store.save(settings)

        let loaded = await store.load()
        XCTAssertEqual(loaded.pngquantBinaryPath, "/tmp/pngquant")
        XCTAssertFalse(loaded.pngquantMarkdownExportEnabled)
        XCTAssertEqual(loaded.pngquantMarkdownExportQualityMin, 60)
        XCTAssertEqual(loaded.pngquantMarkdownExportQualityMax, 75)
        XCTAssertEqual(loaded.pngquantMarkdownExportSpeed, 11)
        XCTAssertEqual(loaded.pngquantMarkdownExportColors, 128)
        XCTAssertTrue(loaded.pngquantCopyImageEnabled)
        XCTAssertEqual(loaded.pngquantCopyImageQualityMin, 55)
        XCTAssertEqual(loaded.pngquantCopyImageQualityMax, 70)
        XCTAssertEqual(loaded.pngquantCopyImageSpeed, 1)
        XCTAssertEqual(loaded.pngquantCopyImageColors, 64)
    }

    func testPollingIntervalClampedWhenDecoding() async {
        let suiteName = "scopy-settingsstore-clamp-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(suiteName: suiteName)

        defaults.set(
            [
                "clipboardPollingIntervalMs": 10
            ],
            forKey: "ScopySettings"
        )
        let minLoaded = await store.load()
        XCTAssertEqual(minLoaded.clipboardPollingIntervalMs, 100)

        defaults.set(
            [
                "clipboardPollingIntervalMs": 99999
            ],
            forKey: "ScopySettings"
        )
        let maxLoaded = await store.load()
        XCTAssertEqual(maxLoaded.clipboardPollingIntervalMs, 2000)
    }

    func testPngquantSettingsClampedWhenDecoding() async {
        let suiteName = "scopy-settingsstore-pngquant-clamp-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(suiteName: suiteName)

        defaults.set(
            [
                "pngquantMarkdownExportSpeed": 999,
                "pngquantMarkdownExportColors": 1,
                "pngquantMarkdownExportQualityMin": 90,
                "pngquantMarkdownExportQualityMax": 10,
                "pngquantCopyImageSpeed": 0,
                "pngquantCopyImageColors": 999
            ],
            forKey: "ScopySettings"
        )

        let loaded = await store.load()
        XCTAssertEqual(loaded.pngquantMarkdownExportSpeed, 11)
        XCTAssertEqual(loaded.pngquantMarkdownExportColors, 2)
        XCTAssertEqual(loaded.pngquantMarkdownExportQualityMin, 90)
        XCTAssertEqual(loaded.pngquantMarkdownExportQualityMax, 90)
        XCTAssertEqual(loaded.pngquantCopyImageSpeed, 1)
        XCTAssertEqual(loaded.pngquantCopyImageColors, 256)
    }
}

@MainActor
final class SearchHintTests: XCTestCase {

    private final class StubClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}
        func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] { [] }
        func search(query: SearchRequest) async throws -> SearchResultPage { SearchResultPage(items: [], total: 0, hasMore: false) }
        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func delete(itemID: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
        func updateSettings(_ settings: SettingsDTO) async throws {}
        func getSettings() async throws -> SettingsDTO { .default }
        func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) { (0, 0) }
        func getDetailedStorageStats() async throws -> StorageStatsDTO {
            StorageStatsDTO(
                itemCount: 0,
                databaseSizeBytes: 0,
                externalStorageSizeBytes: 0,
                thumbnailSizeBytes: 0,
                totalSizeBytes: 0,
                databasePath: ""
            )
        }
        func getImageData(itemID: UUID) async throws -> Data? { nil }
        func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
            ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        func getRecentApps(limit: Int) async throws -> [String] { [] }
    }

    func testExactShortQueryShowsHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .exact
        viewModel.searchQuery = "ab"

        let hint = viewModel.cacheLimitedSearchHint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("2000") ?? false)
    }

    func testExactLongQueryDoesNotShowHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .exact
        viewModel.searchQuery = "abc"

        XCTAssertNil(viewModel.cacheLimitedSearchHint)
    }

    func testRegexShowsHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .regex
        viewModel.searchQuery = "Item \\\\d+"

        let hint = viewModel.cacheLimitedSearchHint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("2000") ?? false)
    }
}
