import XCTest
import ScopyKit

@MainActor
final class SearchStateMachineTests: XCTestCase {

    private enum SyntheticSearchError: Error {
        case invalidQuery
    }

    private final class LifecycleClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        var delayedQueries: Set<String> = []
        var failingQueries: Set<String> = []
        var recordedSearchRequests: [SearchRequest] = []

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}
        func fetchRecent(limit _: Int, offset _: Int) async throws -> [ClipboardItemDTO] { [] }
        func fetchPinned() async throws -> [ClipboardItemDTO] { [] }
        func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            try await fetchRecent(limit: limit, offset: offset)
        }

        func search(query: SearchRequest) async throws -> SearchResultPage {
            recordedSearchRequests.append(query)
            if failingQueries.contains(query.query) {
                throw SyntheticSearchError.invalidQuery
            }
            if delayedQueries.contains(query.query) {
                // Intentionally ignore cancellation so the view model's version boundary is tested.
                try? await Task.sleep(nanoseconds: 180_000_000)
            }

            let item = makeItem(text: "\(query.mode.rawValue) result \(query.query)")
            let context = try SearchMatchContextBuilder.makeContext(
                plainText: item.plainText,
                note: item.note,
                request: query,
                coverage: .complete
            )
            return SearchResultPage(
                hits: [SearchResultHit(item: item, matchContext: context)],
                total: 1,
                hasMore: false,
                coverage: .complete
            )
        }

        func pin(itemID _: UUID) async throws {}
        func unpin(itemID _: UUID) async throws {}
        func updateNote(itemID _: UUID, note _: String?) async throws {}
        func delete(itemID _: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID _: UUID) async throws {}
        func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
            try await copyToClipboard(itemID: itemID)
        }
        func fileURLs(itemID _: UUID) async throws -> [URL] { [] }
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
        func getImageData(itemID _: UUID) async throws -> Data? { nil }
        func optimizeImage(itemID _: UUID) async throws -> ImageOptimizationOutcomeDTO {
            ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }
        func getRecentApps(limit _: Int) async throws -> [String] { [] }

        private func makeItem(text: String) -> ClipboardItemDTO {
            ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: text,
                plainText: text,
                appBundleID: "com.test.lifecycle",
                createdAt: Date(),
                lastUsedAt: Date(),
                isPinned: false,
                sizeBytes: text.utf8.count,
                thumbnailPath: nil,
                storageRef: nil
            )
        }
    }

    private final class ControlledClipboardService: ClipboardServiceProtocol {
        private struct RequestKey: Hashable {
            let query: String
            let offset: Int
        }

        private struct Page {
            let items: [ClipboardItemDTO]
            let total: Int
            let hasMore: Bool
            let coverage: SearchCoverage
        }

        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }
        private(set) var recordedSearchRequests: [SearchRequest] = []

        private var pages: [RequestKey: Page] = [:]
        private var blockedRequests: Set<RequestKey> = []
        private var startedRequests: Set<RequestKey> = []
        private var requestContinuations: [RequestKey: CheckedContinuation<Void, Never>] = [:]

        func setPage(
            query: String,
            offset: Int,
            items: [ClipboardItemDTO],
            total: Int,
            hasMore: Bool,
            coverage: SearchCoverage = .complete
        ) {
            pages[RequestKey(query: query, offset: offset)] = Page(
                items: items,
                total: total,
                hasMore: hasMore,
                coverage: coverage
            )
        }

        func blockRequest(query: String, offset: Int) {
            blockedRequests.insert(RequestKey(query: query, offset: offset))
        }

        func hasStartedRequest(query: String, offset: Int) -> Bool {
            startedRequests.contains(RequestKey(query: query, offset: offset))
        }

        func releaseRequest(query: String, offset: Int) {
            let key = RequestKey(query: query, offset: offset)
            blockedRequests.remove(key)
            requestContinuations.removeValue(forKey: key)?.resume()
        }

        func releaseAllRequests() {
            blockedRequests.removeAll()
            let continuations = Array(requestContinuations.values)
            requestContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}
        func fetchRecent(limit _: Int, offset _: Int) async throws -> [ClipboardItemDTO] { [] }
        func fetchPinned() async throws -> [ClipboardItemDTO] { [] }
        func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            try await fetchRecent(limit: limit, offset: offset)
        }

        func search(query: SearchRequest) async throws -> SearchResultPage {
            recordedSearchRequests.append(query)
            let key = RequestKey(query: query.query, offset: query.offset)
            if blockedRequests.contains(key) {
                startedRequests.insert(key)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    requestContinuations[key] = continuation
                }
            }

            let page = pages[key] ?? Page(
                items: [],
                total: 0,
                hasMore: false,
                coverage: .complete
            )
            let matcher = try SearchMatchContextBuilder.prepare(
                request: query,
                coverage: page.coverage
            )
            return SearchResultPage(
                hits: try page.items.map { item in
                    SearchResultHit(
                        item: item,
                        matchContext: try matcher.makeContext(
                            plainText: item.plainText,
                            note: item.note
                        )
                    )
                },
                total: page.total,
                hasMore: page.hasMore,
                coverage: page.coverage
            )
        }

        func pin(itemID _: UUID) async throws {}
        func unpin(itemID _: UUID) async throws {}
        func updateNote(itemID _: UUID, note _: String?) async throws {}
        func delete(itemID _: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID _: UUID) async throws {}
        func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
            try await copyToClipboard(itemID: itemID)
        }
        func fileURLs(itemID _: UUID) async throws -> [URL] { [] }
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
        func getImageData(itemID _: UUID) async throws -> Data? { nil }
        func optimizeImage(itemID _: UUID) async throws -> ImageOptimizationOutcomeDTO {
            ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }
        func getRecentApps(limit _: Int) async throws -> [String] { [] }
    }

    private final class DelayedClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        var recentItems: [ClipboardItemDTO] = []

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}

        func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            Array(recentItems.dropFirst(offset).prefix(limit))
        }

        func fetchPinned() async throws -> [ClipboardItemDTO] { [] }
        func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            try await fetchRecent(limit: limit, offset: offset)
        }

        func search(query: SearchRequest) async throws -> SearchResultPage {
            if query.query == "a" && query.offset > 0 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled {
                    return SearchResultPage(
                        hits: [],
                        total: 100,
                        hasMore: true,
                        coverage: .complete
                    )
                }

                return SearchResultPage(
                    hits: try [
                        Self.makeItem(text: "a-more-1"),
                        Self.makeItem(text: "a-more-2")
                    ].map { try Self.makeHit(item: $0, request: query) },
                    total: 100,
                    hasMore: true,
                    coverage: .complete
                )
            }

            if query.query == "a" {
                return SearchResultPage(
                    hits: try [
                        Self.makeItem(text: "a-1"),
                        Self.makeItem(text: "a-2")
                    ].map { try Self.makeHit(item: $0, request: query) },
                    total: 100,
                    hasMore: true,
                    coverage: .complete
                )
            }

            return SearchResultPage(hits: [], total: 0, hasMore: false, coverage: .complete)
        }

        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func updateNote(itemID: UUID, note: String?) async throws {}
        func delete(itemID: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
        func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
            try await copyToClipboard(itemID: itemID)
        }
        func fileURLs(itemID: UUID) async throws -> [URL] { [] }
        func updateSettings(_ settings: SettingsDTO) async throws {}
        func getSettings() async throws -> SettingsDTO { .default }
        func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) { (recentItems.count, 0) }
        func getDetailedStorageStats() async throws -> StorageStatsDTO {
            StorageStatsDTO(
                itemCount: recentItems.count,
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

        private static func makeItem(text: String) -> ClipboardItemDTO {
            ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: text,
                plainText: text,
                appBundleID: "com.test.app",
                createdAt: Date(),
                lastUsedAt: Date(),
                isPinned: false,
                sizeBytes: text.utf8.count,
                thumbnailPath: nil,
                storageRef: nil
            )
        }

        private static func makeHit(
            item: ClipboardItemDTO,
            request: SearchRequest
        ) throws -> SearchResultHit {
            SearchResultHit(
                item: item,
                matchContext: try SearchMatchContextBuilder.makeContext(
                    plainText: item.plainText,
                    note: item.note,
                    request: request,
                    coverage: .complete
                )
            )
        }
    }

    private final class RecentOnlyClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        var recentItems: [ClipboardItemDTO] = []
        var recordedSearchRequests: [SearchRequest] = []

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}

        func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            Array(recentItems.dropFirst(offset).prefix(limit))
        }

        func fetchPinned() async throws -> [ClipboardItemDTO] { [] }
        func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            try await fetchRecent(limit: limit, offset: offset)
        }

        func search(query: SearchRequest) async throws -> SearchResultPage {
            recordedSearchRequests.append(query)
            let suffix = query.offset == 0 ? "first" : "more"
            let items = [
                Self.makeItem(text: "\(query.mode.rawValue)-\(suffix)-1"),
                Self.makeItem(text: "\(query.mode.rawValue)-\(suffix)-2")
            ]
            return SearchResultPage(
                hits: items.map { SearchResultHit(item: $0, matchContext: nil) },
                total: 100,
                hasMore: true,
                coverage: .recentOnly(limit: 2000)
            )
        }

        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func updateNote(itemID: UUID, note: String?) async throws {}
        func delete(itemID: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
        func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
            try await copyToClipboard(itemID: itemID)
        }
        func fileURLs(itemID: UUID) async throws -> [URL] { [] }
        func updateSettings(_ settings: SettingsDTO) async throws {}
        func getSettings() async throws -> SettingsDTO { .default }
        func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) { (recentItems.count, 0) }
        func getDetailedStorageStats() async throws -> StorageStatsDTO {
            StorageStatsDTO(
                itemCount: recentItems.count,
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

        private static func makeItem(text: String) -> ClipboardItemDTO {
            ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: text,
                plainText: text,
                appBundleID: "com.test.app",
                createdAt: Date(),
                lastUsedAt: Date(),
                isPinned: false,
                sizeBytes: text.utf8.count,
                thumbnailPath: nil,
                storageRef: nil
            )
        }
    }

    private func makeItem(
        id: UUID = UUID(),
        text: String,
        note: String? = nil
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: .text,
            contentHash: text,
            plainText: text,
            note: note,
            appBundleID: "com.test.state-machine",
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: text.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    private func replacingNote(
        in item: ClipboardItemDTO,
        with note: String?
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            note: note,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes,
            thumbnailPath: item.thumbnailPath,
            storageRef: item.storageRef
        )
    }

    func testClearingSearchCancelsInFlightLoadMore() async {
        let service = DelayedClipboardService()
        service.recentItems = [
            ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: "recent",
                plainText: "recent",
                appBundleID: "com.test.app",
                createdAt: Date(),
                lastUsedAt: Date(),
                isPinned: false,
                sizeBytes: 6,
                thumbnailPath: nil,
                storageRef: nil
            )
        ]

        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)

        viewModel.searchMode = .exact
        viewModel.searchQuery = "a"
        viewModel.search()

        await waitForCondition(timeout: 2.0, pollInterval: 0.01, { viewModel.loadedCount == 2 })
        XCTAssertTrue(viewModel.canLoadMore)
        XCTAssertEqual(viewModel.searchMatchContexts.count, 2)
        XCTAssertTrue(viewModel.items.allSatisfy {
            viewModel.searchMatchContext(for: $0.id) != nil
        })

        let loadMore = Task { await viewModel.loadMore() }
        try? await Task.sleep(nanoseconds: 10_000_000)

        viewModel.searchQuery = ""
        viewModel.search()

        _ = await loadMore.result
        await waitForCondition(timeout: 2.0, pollInterval: 0.01, { viewModel.items.count == 1 })

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items.first?.plainText, "recent")
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)
    }

    func testCancelledLoadMoreCannotClearLoadingOwnedByNewSearch() async {
        let service = ControlledClipboardService()
        defer { service.releaseAllRequests() }

        let alphaFirst = makeItem(text: "alpha first")
        let alphaMore = makeItem(text: "alpha more")
        let betaResult = makeItem(text: "beta result")
        service.setPage(
            query: "alpha",
            offset: 0,
            items: [alphaFirst],
            total: 2,
            hasMore: true
        )
        service.setPage(
            query: "alpha",
            offset: 1,
            items: [alphaMore],
            total: 2,
            hasMore: false
        )
        service.setPage(
            query: "beta",
            offset: 0,
            items: [betaResult],
            total: 1,
            hasMore: false
        )

        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)
        viewModel.searchMode = .exact
        viewModel.searchQuery = "alpha"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.map(\.id) == [alphaFirst.id] && !viewModel.isLoading
        }

        service.blockRequest(query: "alpha", offset: 1)
        let pagingTask = Task { await viewModel.loadMore() }
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.hasStartedRequest(query: "alpha", offset: 1) && viewModel.isLoading
        }

        service.blockRequest(query: "beta", offset: 0)
        viewModel.searchQuery = "beta"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.hasStartedRequest(query: "beta", offset: 0) && viewModel.isLoading
        }

        service.releaseRequest(query: "alpha", offset: 1)
        await pagingTask.value

        XCTAssertTrue(viewModel.isLoading, "The delayed beta search still owns the loading state")
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)

        service.releaseRequest(query: "beta", offset: 0)
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.map(\.id) == [betaResult.id] && !viewModel.isLoading
        }

        XCTAssertEqual(viewModel.items.map(\.id), [betaResult.id])
        XCTAssertNotNil(viewModel.searchMatchContext(for: betaResult.id))
        XCTAssertFalse(viewModel.items.contains { $0.id == alphaMore.id })
    }

    func testExactRecentOnlyPagingDoesNotTriggerFullRefine() async {
        let service = RecentOnlyClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)

        viewModel.searchMode = .exact
        viewModel.searchQuery = "ab"
        viewModel.search()

        await waitForCondition(timeout: 2.0, pollInterval: 0.01, {
            viewModel.loadedCount == 2 && viewModel.canLoadMore && !viewModel.isLoading
        })
        await viewModel.loadMore()

        XCTAssertEqual(service.recordedSearchRequests.count, 2)
        XCTAssertFalse(service.recordedSearchRequests[1].forceFullFuzzy)
        XCTAssertEqual(service.recordedSearchRequests[1].offset, 2)
        XCTAssertEqual(service.recordedSearchRequests[1].limit, HistoryViewModel.loadMorePageSize)
        XCTAssertEqual(viewModel.searchCoverage, .recentOnly(limit: 2000))
    }

    func testRegexRecentOnlyPagingDoesNotTriggerFullRefine() async {
        let service = RecentOnlyClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)

        viewModel.searchMode = .regex
        viewModel.searchQuery = "item\\\\d+"
        viewModel.search()

        await waitForCondition(timeout: 2.0, pollInterval: 0.01, {
            viewModel.loadedCount == 2 && viewModel.canLoadMore && !viewModel.isLoading
        })
        await viewModel.loadMore()

        XCTAssertEqual(service.recordedSearchRequests.count, 2)
        XCTAssertFalse(service.recordedSearchRequests[1].forceFullFuzzy)
        XCTAssertEqual(service.recordedSearchRequests[1].offset, 2)
        XCTAssertEqual(service.recordedSearchRequests[1].limit, HistoryViewModel.loadMorePageSize)
        XCTAssertEqual(viewModel.searchCoverage, .recentOnly(limit: 2000))
    }

    func testReplacingQueryClearsProjectionAndRejectsDelayedOldEvidence() async {
        let service = LifecycleClipboardService()
        service.delayedQueries = ["alpha"]
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)
        viewModel.searchMode = .exact

        viewModel.searchQuery = "alpha"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.recordedSearchRequests.contains { $0.query == "alpha" }
        }

        viewModel.searchQuery = "beta"
        viewModel.search()
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)

        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.first?.plainText.contains("beta") == true && !viewModel.isLoading
        }
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertTrue(viewModel.items[0].plainText.contains("beta"))
        XCTAssertEqual(viewModel.searchMatchContext(for: viewModel.items[0].id)?.mode, .exact)
    }

    func testSearchErrorDoesNotLeaveCandidatesWithoutEvidence() async {
        let service = LifecycleClipboardService()
        service.failingQueries = ["("]
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)

        viewModel.searchMode = .regex
        viewModel.searchQuery = "foo"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.count == 1 && !viewModel.isLoading
        }
        XCTAssertEqual(viewModel.searchMatchContexts.count, 1)

        viewModel.searchQuery = "("
        viewModel.search()
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.recordedSearchRequests.last?.query == "(" && !viewModel.isLoading
        }

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)
    }

    func testPersistedModeChangeWithActiveQueryStartsFreshSearch() async {
        let service = LifecycleClipboardService()
        let settingsViewModel = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settingsViewModel)
        viewModel.configureTiming(.tests)

        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.count == 1 && !viewModel.isLoading
        }
        XCTAssertEqual(service.recordedSearchRequests.last?.mode, .fuzzyPlus)

        var updatedSettings = SettingsDTO.default
        updatedSettings.defaultSearchMode = .exact
        viewModel.applySettings(updatedSettings)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.recordedSearchRequests.last?.mode == .exact && !viewModel.isLoading
        }

        XCTAssertEqual(
            viewModel.items.first.flatMap { viewModel.searchMatchContext(for: $0.id)?.mode },
            .exact
        )
    }

    func testMetadataOnlyItemUpdateKeepsSearchOrderAndEvidenceWithoutRequery() async throws {
        let service = LifecycleClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.count == 1 && !viewModel.isLoading
        }

        let original = try XCTUnwrap(viewModel.items.first)
        let originalContext = try XCTUnwrap(viewModel.searchMatchContext(for: original.id))
        let requestCount = service.recordedSearchRequests.count
        let updated = ClipboardItemDTO(
            id: original.id,
            type: original.type,
            contentHash: original.contentHash,
            plainText: original.plainText,
            note: original.note,
            appBundleID: original.appBundleID,
            createdAt: original.createdAt,
            lastUsedAt: original.lastUsedAt.addingTimeInterval(10),
            isPinned: original.isPinned,
            sizeBytes: original.sizeBytes,
            fileSizeBytes: original.fileSizeBytes,
            thumbnailPath: original.thumbnailPath,
            storageRef: original.storageRef
        )

        await viewModel.handleEvent(.itemUpdated(updated))

        XCTAssertEqual(service.recordedSearchRequests.count, requestCount)
        XCTAssertEqual(viewModel.items.map(\.id), [original.id])
        XCTAssertEqual(viewModel.items.first?.lastUsedAt, updated.lastUsedAt)
        XCTAssertEqual(viewModel.searchMatchContext(for: original.id), originalContext)
    }

    func testContentUpdateReplacesThenRemovesEvidenceForActiveQuery() async throws {
        let service = ControlledClipboardService()
        let itemID = UUID()
        let original = makeItem(
            id: itemID,
            text: "document body",
            note: "needle old note"
        )
        service.setPage(
            query: "needle",
            offset: 0,
            items: [original],
            total: 1,
            hasMore: false
        )

        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.map(\.id) == [itemID] && !viewModel.isLoading
        }

        let originalContext = try XCTUnwrap(viewModel.searchMatchContext(for: itemID))
        let updated = replacingNote(in: original, with: "needle replacement note")
        service.setPage(
            query: "needle",
            offset: 0,
            items: [updated],
            total: 1,
            hasMore: false
        )
        let requestCount = service.recordedSearchRequests.count

        await viewModel.handleEvent(.itemContentUpdated(updated))
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.recordedSearchRequests.count == requestCount + 1
                && viewModel.items.first?.note == updated.note
                && !viewModel.isLoading
        }

        let replacementContext = try XCTUnwrap(viewModel.searchMatchContext(for: itemID))
        XCTAssertNotEqual(replacementContext, originalContext)
        XCTAssertTrue(replacementContext.fragments.contains { fragment in
            fragment.source == .note && fragment.text.contains("replacement")
        })

        let noLongerMatching = replacingNote(in: updated, with: "no longer matching")
        service.setPage(
            query: "needle",
            offset: 0,
            items: [],
            total: 0,
            hasMore: false
        )
        await viewModel.handleEvent(.itemContentUpdated(noLongerMatching))
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            service.recordedSearchRequests.count == requestCount + 2 && !viewModel.isLoading
        }

        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNil(viewModel.searchMatchContext(for: itemID))
        XCTAssertTrue(viewModel.searchMatchContexts.isEmpty)
    }

    func testSuccessfulLoadMorePreservesExistingEvidenceAndAddsCompleteNewEvidence() async throws {
        let service = ControlledClipboardService()
        let first = makeItem(text: "needle first page one")
        let second = makeItem(text: "needle first page two")
        let third = makeItem(text: "needle later page three")
        let fourth = makeItem(text: "needle later page four")
        service.setPage(
            query: "needle",
            offset: 0,
            items: [first, second],
            total: 4,
            hasMore: true
        )
        service.setPage(
            query: "needle",
            offset: 2,
            items: [third, fourth],
            total: 4,
            hasMore: false
        )

        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)
        viewModel.configureTiming(.tests)
        viewModel.searchMode = .exact
        viewModel.searchQuery = "needle"
        viewModel.search()
        await waitForCondition(timeout: 1.0, pollInterval: 0.005) {
            viewModel.items.map(\.id) == [first.id, second.id]
                && viewModel.searchMatchContexts.count == 2
                && !viewModel.isLoading
        }

        let firstContext = try XCTUnwrap(viewModel.searchMatchContext(for: first.id))
        let secondContext = try XCTUnwrap(viewModel.searchMatchContext(for: second.id))
        await viewModel.loadMore()

        XCTAssertEqual(
            viewModel.items.map(\.id),
            [first.id, second.id, third.id, fourth.id]
        )
        XCTAssertEqual(viewModel.searchMatchContexts.count, 4)
        XCTAssertEqual(viewModel.searchMatchContext(for: first.id), firstContext)
        XCTAssertEqual(viewModel.searchMatchContext(for: second.id), secondContext)
        XCTAssertTrue(viewModel.items.allSatisfy { item in
            viewModel.searchMatchContext(for: item.id) != nil
        })
        XCTAssertNotNil(viewModel.searchMatchContext(for: third.id))
        XCTAssertNotNil(viewModel.searchMatchContext(for: fourth.id))
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertEqual(service.recordedSearchRequests.last?.offset, 2)
    }
}
