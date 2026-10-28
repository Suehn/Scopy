import AppKit
import XCTest
import ScopyKit

@MainActor
final class PollingIntervalSettingTests: XCTestCase {

    private var service: (any ClipboardServiceProtocol)!
    private var tempDirectory: URL?
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!

    override func setUp() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-polling-interval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        tempDirectory = baseURL

        settingsStore = SettingsStore(suiteName: baseURL.appendingPathComponent("settings").path)
        var settings = await settingsStore.load()
        settings.clipboardPollingIntervalMs = 2000
        await settingsStore.save(settings)

        pasteboard = NSPasteboard.withUniqueName()

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        service = ClipboardServiceFactory.create(
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
    private var settingsDirectory: URL!

    override func setUpWithError() throws {
        settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-settingsstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: settingsDirectory)
    }

    func testSaveAndLoadPollingIntervalPersists() async {
        let suiteName = settingsDirectory.appendingPathComponent("settings").path

        let store = SettingsStore(suiteName: suiteName)

        var settings = await store.load()
        settings.clipboardPollingIntervalMs = 1200
        await store.save(settings)

        let loaded = await store.load()
        XCTAssertEqual(loaded.clipboardPollingIntervalMs, 1200)
    }

    func testSaveAndLoadMarkdownLayoutScalePersists() async {
        let suiteName = settingsDirectory.appendingPathComponent("settings").path

        let store = SettingsStore(suiteName: suiteName)

        var settings = await store.load()
        settings.markdownChatGPTLayoutScalePercent = 125
        await store.save(settings)

        let loaded = await store.load()
        XCTAssertEqual(loaded.markdownChatGPTLayoutScalePercent, 125)
    }

    func testSaveAndLoadPngquantSettingsPersist() async {
        let suiteName = settingsDirectory.appendingPathComponent("settings").path

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
        let suiteName = settingsDirectory.appendingPathComponent("settings").path

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

    func testMarkdownLayoutScaleClampedWhenDecoding() async {
        let suiteName = settingsDirectory.appendingPathComponent("settings").path

        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(suiteName: suiteName)

        defaults.set(
            [
                "markdownChatGPTLayoutScalePercent": 175
            ],
            forKey: "ScopySettings"
        )

        let loaded = await store.load()
        XCTAssertEqual(loaded.markdownChatGPTLayoutScalePercent, 175)

        defaults.set(
            [
                "markdownChatGPTLayoutScalePercent": 50
            ],
            forKey: "ScopySettings"
        )
        let minLoaded = await store.load()
        XCTAssertEqual(minLoaded.markdownChatGPTLayoutScalePercent, 80)

        defaults.set(
            [
                "markdownChatGPTLayoutScalePercent": 250
            ],
            forKey: "ScopySettings"
        )
        let maxLoaded = await store.load()
        XCTAssertEqual(maxLoaded.markdownChatGPTLayoutScalePercent, 200)
    }

    func testPngquantSettingsClampedWhenDecoding() async {
        let suiteName = settingsDirectory.appendingPathComponent("settings").path

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
        func fetchPinned() async throws -> [ClipboardItemDTO] { [] }
        func fetchHistoryPage(limit _: Int, after _: RecentHistoryCursor?) async throws -> RecentHistoryPage {
            RecentHistoryPage(pinnedItems: [], items: [], total: 0, nextCursor: nil, mutationSeq: 0)
        }

        func fetchHistoryItems(itemIDs: Set<UUID>) async throws -> HistoryItemsSnapshot {
            HistoryItemsSnapshot(requestedItemIDs: itemIDs, items: [], mutationSeq: 0)
        }
        func search(query: SearchRequest) async throws -> SearchResultPage {
            SearchResultPage(hits: [], total: 0, hasMore: false, coverage: .complete, mutationSeq: 0)
        }
        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func updateNote(itemID: UUID, note: String?) async throws {}
        func delete(itemID: UUID, expectedUseCount: Int) async throws -> HistoryItemsSnapshot {
            HistoryItemsSnapshot(requestedItemIDs: [itemID], items: [], mutationSeq: 0)
        }
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
        func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {}
        func fileURLs(itemID: UUID) async throws -> [URL] { [] }
        func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
            SettingsDTO.default.applying(patch)
        }
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
        func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }
        func getRecentApps(limit: Int) async throws -> [String] { [] }
    }

    func testExactShortQueryShowsHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .exact
        viewModel.searchQuery = "ab"

        let hint = viewModel.searchCoverageHint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("2000") ?? false)
    }

    func testExactLongQueryDoesNotShowHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .exact
        viewModel.searchQuery = "abc"

        XCTAssertNil(viewModel.searchCoverageHint)
    }

    func testRegexShowsHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .regex
        viewModel.searchQuery = "Item \\\\d+"

        let hint = viewModel.searchCoverageHint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("2000") ?? false)
    }

    func testFuzzyStagedCoverageShowsProgressHint() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        viewModel.searchMode = .fuzzyPlus
        viewModel.searchQuery = "cmd"
        viewModel.searchCoverage = .stagedRefine

        let hint = viewModel.searchCoverageHint
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("full search") ?? false)
    }

    func testApplySettingsDoesNotOverrideManualSessionSearchMode() {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        var initial = SettingsDTO.default
        initial.defaultSearchMode = .exact
        viewModel.applySettings(initial)

        viewModel.searchMode = .regex

        var updated = SettingsDTO.default
        updated.defaultSearchMode = .fuzzyPlus
        viewModel.applySettings(updated)

        XCTAssertEqual(viewModel.searchMode, .regex)
    }
}
