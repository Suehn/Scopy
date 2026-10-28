import AppKit
import SwiftUI
import XCTest
import ScopyKit

@testable import Scopy

/// Service selection, event delivery and application callback wiring.
@MainActor
final class AppStateTests: XCTestCase {

    var appState: AppState!
    var mockService: TestMockClipboardService!

    override func setUp() async throws {
        mockService = TestMockClipboardService()
        appState = AppState.forTesting(service: mockService)
    }

    override func tearDown() async throws {
        await appState.stop()
        appState = nil
        mockService = nil
    }

    func testReleaseNeverUsesMockAndDebugUITestingDefaultsToMockUnlessDisabled() {
        XCTAssertFalse(
            AppState.shouldUseMockService(
                arguments: ["Scopy", "--uitesting"],
                environment: [:],
                isDebugBuild: false
            )
        )
        XCTAssertTrue(
            AppState.shouldUseMockService(
                arguments: ["Scopy", "--uitesting"],
                environment: [:],
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            AppState.shouldUseMockService(
                arguments: ["Scopy", "--uitesting"],
                environment: ["USE_MOCK_SERVICE": "0"],
                isDebugBuild: true
            )
        )
    }

    func testOrdinaryReleaseLaunchCannotEnableMockFromEnvironmentAlone() {
        XCTAssertFalse(
            AppState.shouldUseMockService(
                arguments: ["Scopy"],
                environment: ["USE_MOCK_SERVICE": "1"],
                isDebugBuild: false
            )
        )
    }

    func testOrdinaryDebugLaunchUsesRealServiceUnlessMockIsExplicitlyEnabled() {
        XCTAssertFalse(
            AppState.shouldUseMockService(
                arguments: ["Scopy"],
                environment: [:],
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            AppState.shouldUseMockService(
                arguments: ["Scopy"],
                environment: ["USE_MOCK_SERVICE": "0"],
                isDebugBuild: true
            )
        )
        XCTAssertTrue(
            AppState.shouldUseMockService(
                arguments: ["Scopy"],
                environment: ["USE_MOCK_SERVICE": "1"],
                isDebugBuild: true
            )
        )
    }

    func testSelectOptimizedForCodexCopiesAndRequestsPaste() async {
        mockService.setItemCount(10)
        await appState.historyViewModel.load()

        let item = appState.historyViewModel.items[0]
        var pasteRequestCount = 0
        appState.pasteAfterCopyHandler = {
            pasteRequestCount += 1
        }

        await appState.historyViewModel.selectOptimizedForCodex(item)

        XCTAssertEqual(mockService.copyCallCount, 1)
        XCTAssertEqual(mockService.lastCopiedItemID, item.id)
        XCTAssertEqual(pasteRequestCount, 1)
    }

    func testClearAllAppliesPublishedDeletionSetWithoutReloading() async throws {
        mockService.setItemCount(3, pinnedCount: 1)
        let subscribed = expectation(description: "Event listener subscribed")
        mockService.onEventStreamSubscribed = { subscribed.fulfill() }
        await appState.start()
        await fulfillment(of: [subscribed], timeout: 1.0)
        let pinnedID = try XCTUnwrap(appState.historyViewModel.pinnedItems.first?.id)
        let refreshCountBeforeClear = mockService.historyPageFetchCallCount
        let clearHandled = expectation(description: "Clear event handled before sentinel")
        appState.applyHotKeyHandler = { _, _ in
            clearHandled.fulfill()
            return true
        }

        await appState.historyViewModel.clearAll()
        mockService.emitEvent(.settingsChanged)
        await fulfillment(of: [clearHandled], timeout: 1.0)

        XCTAssertEqual(mockService.clearAllCallCount, 1)
        XCTAssertEqual(mockService.historyPageFetchCallCount, refreshCountBeforeClear, "Exact committed IDs need no survivor reload")
        XCTAssertEqual(appState.historyViewModel.items.map(\.id), [pinnedID])
    }

    func testPanelReopenPolicyClearsOnlyAfterThreshold() throws {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200)) { EmptyView() }
        let threshold = PanelReopenSearchResetPolicy.staleIntervalSeconds

        XCTAssertFalse(panel.wasClosedLongerThan(threshold))
        panel.close()
        let closedAt = try XCTUnwrap(panel.lastClosedAt)
        XCTAssertFalse(panel.wasClosedLongerThan(threshold, now: closedAt.addingTimeInterval(threshold)))
        XCTAssertTrue(panel.wasClosedLongerThan(threshold, now: closedAt.addingTimeInterval(threshold + 1)))
    }

}

/// Shared service used by lifecycle, query isolation and content-revision tests.
@MainActor
final class TestMockClipboardService: ClipboardServiceProtocol {
    private var items: [ClipboardItemDTO] = []
    private var settings: SettingsDTO = .default
    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?

    var startCallCount = 0
    var stopCallCount = 0
    var startFailuresRemaining = 0
    var onStart: (@MainActor () async -> Void)?
    var onStop: (@MainActor () async -> Void)?

    // Call tracking
    var searchCallCount = 0
    var searchStartedQueries: [String] = []
    var lastSearchQuery: String?
    var copyCallCount = 0
    var lastCopiedItemID: UUID?
    var clearAllCallCount = 0
    var fetchRecentCallCount = 0
    var historyPageFetchCallCount = 0
    var onEventStreamSubscribed: (() -> Void)?

    // Artificial delays (for race-condition tests)
    var fetchRecentDelayNs: UInt64 = 0
    var fetchPinnedFailuresRemaining = 0
    var searchDelayNs: UInt64 = 0
    var searchDelayNsByQuery: [String: UInt64] = [:]
    /// When true, the artificial search delay will not be interrupted by task cancellation (simulates a backend that can't cancel promptly).
    var searchDelayIgnoresCancellation: Bool = false

    var eventStream: AsyncStream<ClipboardEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
            self.onEventStreamSubscribed?()
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        startCallCount += 1
        await onStart?()
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw FailingMockService.TestError.simulatedFailure
        }
    }

    func stop() {
        stopCallCount += 1
        eventContinuation?.finish()
    }

    func stopAndWait() async {
        await onStop?()
        stop()
    }

    // MARK: - Setup Helpers

    func setItemCount(_ count: Int, pinnedCount: Int = 0) {
        items = (0..<count).map { i in
            ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: "hash\(i)",
                plainText: "Test item \(i)",
                appBundleID: "com.test.app",
                createdAt: Date().addingTimeInterval(Double(-i * 60)),
                lastUsedAt: Date().addingTimeInterval(Double(-i * 30)),
                isPinned: i < pinnedCount,
                sizeBytes: 20 + i,
                thumbnailPath: nil,
                storageRef: nil,
                useCount: 1
            )
        }
    }

    func itemID(at index: Int) -> UUID {
        items[index].id
    }

    func resetSearchCallCount() {
        searchCallCount = 0
        searchStartedQueries = []
        lastSearchQuery = nil
    }

    func emitEvent(_ event: ClipboardEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Protocol Implementation

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        fetchRecentCallCount += 1
        if fetchRecentDelayNs > 0 {
            do {
                try await Task.sleep(nanoseconds: fetchRecentDelayNs)
            } catch {
                return []
            }
        }
        let sortedItems = items.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let start = min(offset, sortedItems.count)
        let end = min(offset + limit, sortedItems.count)
        return Array(sortedItems[start..<end])
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        fetchRecentCallCount += 1
        if fetchPinnedFailuresRemaining > 0 {
            fetchPinnedFailuresRemaining -= 1
            throw FailingMockService.TestError.simulatedFailure
        }
        return items.filter(\.isPinned).sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private var mutationSeq: Int64 = 0

    func historyEvent(_ change: HistoryChange) -> ClipboardEvent {
        mutationSeq += 1
        return .history(CommittedHistoryChange(mutationSeq: mutationSeq, totalCount: items.count, change: change))
    }

    func fetchHistoryPage(limit: Int, after cursor: RecentHistoryCursor?) async throws -> RecentHistoryPage {
        if cursor == nil { _ = try await fetchPinned() }
        fetchRecentCallCount += 1
        historyPageFetchCallCount += 1
        if fetchRecentDelayNs > 0 {
            try await Task.sleep(nanoseconds: fetchRecentDelayNs)
        }
        return RecentHistoryPage(slicing: items, limit: limit, after: cursor, mutationSeq: mutationSeq)
    }

    func fetchHistoryItems(itemIDs: Set<UUID>) async throws -> HistoryItemsSnapshot {
        HistoryItemsSnapshot(requestedItemIDs: itemIDs, items: items.filter { itemIDs.contains($0.id) }, mutationSeq: mutationSeq)
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        searchStartedQueries.append(query.query)
        let effectiveDelayNs = searchDelayNsByQuery[query.query] ?? searchDelayNs
        if effectiveDelayNs > 0 {
            if searchDelayIgnoresCancellation {
                await Self.sleepUncancellable(nanoseconds: effectiveDelayNs)
            } else {
                do {
                    try await Task.sleep(nanoseconds: effectiveDelayNs)
                } catch {
                    return SearchResultPage(
                        hits: [],
                        total: 0,
                        hasMore: false,
                        coverage: .complete,
                        mutationSeq: mutationSeq
                    )
                }
            }
        }
        searchCallCount += 1
        lastSearchQuery = query.query

        let filtered: [ClipboardItemDTO]
        if query.query.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { $0.plainText.localizedCaseInsensitiveContains(query.query) }
        }

        let start = min(query.offset, filtered.count)
        let end = min(query.offset + query.limit, filtered.count)

        return SearchResultPage(
            hits: filtered[start..<end].map {
                SearchResultHit(item: $0, matchContext: nil)
            },
            total: filtered.count,
            hasMore: end < filtered.count,
            coverage: .complete,
            mutationSeq: mutationSeq
        )
    }

    nonisolated private static func sleepUncancellable(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds))
            ) {
                continuation.resume()
            }
        }
    }

    func pin(itemID: UUID) async throws {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id, type: item.type, contentHash: item.contentHash,
                plainText: item.plainText, appBundleID: item.appBundleID,
                createdAt: item.createdAt, lastUsedAt: item.lastUsedAt,
                isPinned: true, sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath, storageRef: item.storageRef,
                useCount: item.useCount
            )
        }
    }

    func unpin(itemID: UUID) async throws {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id, type: item.type, contentHash: item.contentHash,
                plainText: item.plainText, appBundleID: item.appBundleID,
                createdAt: item.createdAt, lastUsedAt: item.lastUsedAt,
                isPinned: false, sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath, storageRef: item.storageRef,
                useCount: item.useCount
            )
        }
    }

    func updateNote(itemID _: UUID, note _: String?) async throws {}

    func delete(itemID: UUID, expectedUseCount: Int) async throws -> HistoryItemsSnapshot {
        if let item = items.first(where: { $0.id == itemID }), item.useCount == expectedUseCount {
            items.removeAll { $0.id == itemID }
            mutationSeq += 1
        }
        return HistoryItemsSnapshot(requestedItemIDs: [itemID], items: items.filter { $0.id == itemID }, mutationSeq: mutationSeq)
    }

    func clearAll() async throws {
        clearAllCallCount += 1
        let removedIDs = items.filter { !$0.isPinned }.map(\.id)
        items = items.filter(\.isPinned)
        eventContinuation?.yield(historyEvent(.itemsCleared(deletedItemIDs: removedIDs)))
    }

    func copyToClipboard(itemID: UUID) async throws {
        copyCallCount += 1
        lastCopiedItemID = itemID
    }

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID)
    }

    func fileURLs(itemID _: UUID) async throws -> [URL] { [] }

    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO {
        settings = settings.applying(patch)
        return settings
    }

    func getSettings() async throws -> SettingsDTO {
        return settings
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        return (items.count, totalBytes)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        return StorageStatsDTO(
            itemCount: items.count,
            databaseSizeBytes: totalBytes,
            externalStorageSizeBytes: 0,
            thumbnailSizeBytes: 0,
            totalSizeBytes: totalBytes,
            databasePath: "~/Library/Application Support/Scopy/"
        )
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        // The mock stores no image data.
        return nil
    }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        guard let item = items.first(where: { $0.id == itemID }) else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: item.sizeBytes, optimizedBytes: item.sizeBytes)
    }

    func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }

    func getRecentApps(limit: Int) async throws -> [String] {
        // The apps present in the mock data.
        let apps = Set(items.compactMap { $0.appBundleID })
        return Array(apps.prefix(limit))
    }
}

/// A startup failure must remain visible instead of silently replacing the service.
@MainActor
final class FailingMockService: ClipboardServiceProtocol {
    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?

    var eventStream: AsyncStream<ClipboardEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    enum TestError: Error {
        case simulatedFailure
    }

    func start() async throws {
        throw TestError.simulatedFailure
    }

    func stop() {
        eventContinuation?.finish()
    }

    func stopAndWait() async {
        stop()
    }

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
        StorageStatsDTO(itemCount: 0, databaseSizeBytes: 0, externalStorageSizeBytes: 0, thumbnailSizeBytes: 0, totalSizeBytes: 0, databasePath: "")
    }
    func getImageData(itemID: UUID) async throws -> Data? { nil }
    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
    }
    func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }
    func getRecentApps(limit: Int) async throws -> [String] { [] }
}

@MainActor
final class AppStateFallbackTests: XCTestCase {

    func testConcurrentStartsWaitForTheSameStartup() async {
        let service = TestMockClipboardService()
        let state = AppState.forTesting(service: service)
        let startupEntered = expectation(description: "Backend startup entered")
        var startupContinuation: CheckedContinuation<Void, Never>?
        service.onStart = {
            await withCheckedContinuation { continuation in
                startupContinuation = continuation
                startupEntered.fulfill()
            }
        }

        let first = Task { await state.start() }
        await fulfillment(of: [startupEntered], timeout: 1)
        let secondEntered = expectation(description: "Second caller starts")
        var secondReturned = false
        let second = Task {
            secondEntered.fulfill()
            await state.start()
            secondReturned = true
        }
        await fulfillment(of: [secondEntered], timeout: 1)

        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertFalse(secondReturned, "Every start caller waits until startup has actually settled")
        startupContinuation?.resume()
        await first.value
        await second.value
        XCTAssertEqual(state.startupPhase, .running)
        await state.stop()
    }

    func testStopJoinsStartupAndKeepsEventsAliveUntilBackendShutdownFinishes() async {
        let service = TestMockClipboardService()
        let state = AppState.forTesting(service: service)
        let startupEntered = expectation(description: "Backend startup entered")
        let shutdownEntered = expectation(description: "Backend shutdown entered")
        var startupContinuation: CheckedContinuation<Void, Never>?
        var shutdownContinuations: [CheckedContinuation<Void, Never>] = []
        service.onStart = {
            await withCheckedContinuation { continuation in
                startupContinuation = continuation
                startupEntered.fulfill()
            }
        }
        service.onStop = {
            await withCheckedContinuation { continuation in
                shutdownContinuations.append(continuation)
                if shutdownContinuations.count == 1 { shutdownEntered.fulfill() }
            }
        }
        let startup = Task { await state.start() }
        await fulfillment(of: [startupEntered], timeout: 1)

        let stopRequested = expectation(description: "Stop requested during startup")
        let shutdown = Task {
            stopRequested.fulfill()
            await state.stop()
        }
        await fulfillment(of: [stopRequested], timeout: 1)
        XCTAssertEqual(service.stopCallCount, 0)
        XCTAssertTrue(shutdownContinuations.isEmpty, "Backend shutdown must not overlap its startup")

        startupContinuation?.resume()
        await startup.value
        await fulfillment(of: [shutdownEntered], timeout: 1)
        let eventHandled = expectation(description: "Event handled during backend shutdown")
        state.applyHotKeyHandler = { _, _ in
            eventHandled.fulfill()
            return true
        }
        service.emitEvent(.settingsChanged)
        await fulfillment(of: [eventHandled], timeout: 1)

        let secondStopRequested = expectation(description: "Second stop requested")
        var secondStopReturned = false
        let secondShutdown = Task {
            secondStopRequested.fulfill()
            await state.stop()
            secondStopReturned = true
        }
        await fulfillment(of: [secondStopRequested], timeout: 1)
        XCTAssertFalse(secondStopReturned, "Concurrent stop callers join backend shutdown")
        XCTAssertEqual(shutdownContinuations.count, 1)
        shutdownContinuations.forEach { $0.resume() }
        await shutdown.value
        await secondShutdown.value

        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(service.historyPageFetchCallCount, 0, "Stopping startup skips initial history loads")
        XCTAssertEqual(state.startupPhase, .idle, "A late startup must not publish running after stop")
    }

    func testStartRecordsStartupFailureWithoutFallback() async {
        let failingService = FailingMockService()
        let state = AppState.forTesting(service: failingService)

        XCTAssertTrue(state.service is FailingMockService)

        await state.start()

        guard case .startupFailed(let failure) = state.startupPhase else {
            await state.stop()
            return XCTFail("Expected startup failure state")
        }

        XCTAssertTrue(state.service is FailingMockService, "Failing service should not be replaced with mock data")
        XCTAssertEqual(state.historyViewModel.items, [])
        XCTAssertEqual(state.historyViewModel.totalCount, 0)
        XCTAssertTrue(failure.diagnostics.contains("Scopy startup failed"))
        XCTAssertTrue(failure.diagnostics.contains("FailingMockService"))

        await state.stop()
    }

    func testRetryStartRecoversAfterTransientFailure() async {
        let service = TestMockClipboardService()
        service.startFailuresRemaining = 1
        service.setItemCount(3)
        let state = AppState.forTesting(service: service)
        addTeardownBlock {
            await state.stop()
        }

        await state.start()
        guard case .startupFailed = state.startupPhase else {
            return XCTFail("Expected first start to fail")
        }
        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertTrue(state.historyViewModel.items.isEmpty)

        await state.start()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            state.startupPhase == .running && state.historyViewModel.items.count == 3
        }, message: "Retry should recover startup and load history")

        XCTAssertEqual(service.startCallCount, 2)

        await state.start()
        XCTAssertEqual(service.startCallCount, 2, "Starting a running service must not subscribe twice")
        let stopCount = service.stopCallCount
        await state.stop()
        XCTAssertEqual(service.stopCallCount, stopCount + 1)
        XCTAssertEqual(state.startupPhase, .idle)
    }

    func testCopyStartupDiagnosticsWritesFailureDetailsToPasteboard() async {
        let failingService = FailingMockService()
        let state = AppState.forTesting(service: failingService)
        addTeardownBlock {
            await state.stop()
        }

        await state.start()
        state.copyStartupDiagnosticsToPasteboard()

        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("Scopy startup failed"))
        XCTAssertTrue(copied.contains("FailingMockService"))
    }

    /// Test that settingsChanged event triggers hotkey callback with latest settings
    func testSettingsChangedAppliesHotkey() async throws {
        let mockService = TestMockClipboardService()
        let state = AppState.forTesting(service: mockService)
        addTeardownBlock {
            await state.stop()
        }

        var hotkeyApplied = false
        var appliedKeyCode: UInt32 = 0
        var appliedModifiers: UInt32 = 0

        state.applyHotKeyHandler = { keyCode, modifiers in
            hotkeyApplied = true
            appliedKeyCode = keyCode
            appliedModifiers = modifiers
            return true
        }

        await state.start()
        let fetchCountAfterStart = mockService.fetchRecentCallCount

        var settings = SettingsDTO.default
        settings.hotkeyKeyCode += 1
        settings.hotkeyModifiers += 1
        _ = try await mockService.updateSettings(SettingsPatch.from(baseline: .default, draft: settings))
        mockService.emitEvent(.settingsChanged)

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            hotkeyApplied
        }, message: "Hotkey handler should be called on settingsChanged")

        XCTAssertEqual(appliedKeyCode, settings.hotkeyKeyCode)
        XCTAssertEqual(appliedModifiers, settings.hotkeyModifiers)
        XCTAssertEqual(mockService.fetchRecentCallCount, fetchCountAfterStart)
    }

    func testSettingsChangedReloadsHistoryForThumbnailSettingsChange() async throws {
        let mockService = TestMockClipboardService()
        mockService.setItemCount(3)
        let state = AppState.forTesting(service: mockService)
        addTeardownBlock {
            await state.stop()
        }

        await state.start()
        let fetchCountAfterStart = mockService.fetchRecentCallCount

        var settings = SettingsDTO.default
        settings.thumbnailHeight = SettingsDTO.default.thumbnailHeight + 8
        _ = try await mockService.updateSettings(SettingsPatch.from(baseline: .default, draft: settings))
        mockService.emitEvent(.settingsChanged)

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            mockService.fetchRecentCallCount > fetchCountAfterStart
        }, message: "thumbnail settings changes should reload history so thumbnail paths are refreshed")
    }

    func testThumbnailUpdatedUpdatesItemWithoutReordering() async throws {
        let mockService = TestMockClipboardService()
        mockService.setItemCount(5)
        let state = AppState.forTesting(service: mockService)
        addTeardownBlock {
            await state.stop()
        }

        await state.start()

        let originalOrder = state.historyViewModel.items.map(\.id)
        let targetID = state.historyViewModel.items[2].id
        let target = try XCTUnwrap(state.historyViewModel.items.first(where: { $0.id == targetID }))
        let thumbnailPath = "/tmp/scopy-test-thumbnail-\(UUID().uuidString).png"

        mockService.emitEvent(
            .thumbnailUpdated(
                itemID: targetID,
                expectedType: target.type,
                expectedContentHash: target.contentHash,
                thumbnailPath: thumbnailPath
            )
        )
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            state.historyViewModel.items.first(where: { $0.id == targetID })?.thumbnailPath == thumbnailPath
        }, message: "Thumbnail path should be updated in place")

        XCTAssertEqual(state.historyViewModel.items.map(\.id), originalOrder, "Thumbnail updates should not reorder items")
        XCTAssertEqual(
            state.historyViewModel.items.first(where: { $0.id == targetID })?.thumbnailPath,
            thumbnailPath,
            "Thumbnail path should be updated in place"
        )
    }

    func testThumbnailUpdatedRejectsAStaleContentRevision() async throws {
        let mockService = TestMockClipboardService()
        mockService.setItemCount(5)
        let state = AppState.forTesting(service: mockService)
        addTeardownBlock {
            await state.stop()
        }

        await state.start()

        let target = try XCTUnwrap(state.historyViewModel.items.first(where: { !$0.isPinned }))
        let validPath = "/tmp/scopy-current-thumbnail-\(UUID().uuidString).png"
        mockService.emitEvent(
            .thumbnailUpdated(
                itemID: target.id,
                expectedType: target.type,
                expectedContentHash: target.contentHash,
                thumbnailPath: validPath
            )
        )
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            state.historyViewModel.items.first(where: { $0.id == target.id })?.thumbnailPath == validPath
        }, message: "Current thumbnail should be applied")

        mockService.emitEvent(
            .thumbnailUpdated(
                itemID: target.id,
                expectedType: target.type,
                expectedContentHash: "superseded-\(target.contentHash)",
                thumbnailPath: "/tmp/scopy-stale-thumbnail.png"
            )
        )
        // A following event is the ordering sentinel: once pinning is visible, the stale thumbnail
        // event ahead of it in the stream has also been handled.
        mockService.emitEvent(mockService.historyEvent(.itemsChanged([target.withPinned(true)], kind: .pin)))
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            state.historyViewModel.items.first(where: { $0.id == target.id })?.isPinned == true
        }, message: "Sentinel event should be processed")

        XCTAssertEqual(
            state.historyViewModel.items.first(where: { $0.id == target.id })?.thumbnailPath,
            validPath,
            "A thumbnail generated for an older content hash must not attach to the replacement"
        )

        let replacement = ClipboardItemDTO(
            id: target.id, type: target.type, contentHash: "replacement-\(target.contentHash)",
            plainText: "replacement payload", note: target.note, appBundleID: target.appBundleID,
            createdAt: target.createdAt, lastUsedAt: target.lastUsedAt, isPinned: true,
            sizeBytes: 19, fileSizeBytes: target.fileSizeBytes, thumbnailPath: nil,
            storageRef: target.storageRef, useCount: target.useCount
        )
        mockService.emitEvent(mockService.historyEvent(.itemsChanged([replacement], kind: .content)))
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            state.historyViewModel.items.first(where: { $0.id == target.id })?.contentHash == replacement.contentHash
        }, message: "Replacement content should be applied")
        XCTAssertNil(
            state.historyViewModel.items.first(where: { $0.id == target.id })?.thumbnailPath,
            "A changed content identity must not inherit the old thumbnail"
        )
    }
}
