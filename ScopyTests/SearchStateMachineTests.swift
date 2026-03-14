import XCTest
import ScopyKit

@MainActor
final class SearchStateMachineTests: XCTestCase {

    private final class DelayedClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        var recentItems: [ClipboardItemDTO] = []

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}

        func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
            Array(recentItems.dropFirst(offset).prefix(limit))
        }

        func search(query: SearchRequest) async throws -> SearchResultPage {
            if query.query == "a" && query.offset > 0 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled {
                    return SearchResultPage(items: [], total: 100, hasMore: true)
                }

                return SearchResultPage(
                    items: [
                        Self.makeItem(text: "a-more-1"),
                        Self.makeItem(text: "a-more-2")
                    ],
                    total: 100,
                    hasMore: true
                )
            }

            if query.query == "a" {
                return SearchResultPage(
                    items: [
                        Self.makeItem(text: "a-1"),
                        Self.makeItem(text: "a-2")
                    ],
                    total: 100,
                    hasMore: true
                )
            }

            return SearchResultPage(items: [], total: 0, hasMore: false)
        }

        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func delete(itemID: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
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

        func search(query: SearchRequest) async throws -> SearchResultPage {
            recordedSearchRequests.append(query)
            let suffix = query.offset == 0 ? "first" : "more"
            let items = [
                Self.makeItem(text: "\(query.mode.rawValue)-\(suffix)-1"),
                Self.makeItem(text: "\(query.mode.rawValue)-\(suffix)-2")
            ]
            return SearchResultPage(
                items: items,
                total: 100,
                hasMore: true,
                coverage: .recentOnly(limit: 2000)
            )
        }

        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func delete(itemID: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
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

        let loadMore = Task { await viewModel.loadMore() }
        try? await Task.sleep(nanoseconds: 10_000_000)

        viewModel.searchQuery = ""
        viewModel.search()

        _ = await loadMore.result
        await waitForCondition(timeout: 2.0, pollInterval: 0.01, { viewModel.items.count == 1 })

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items.first?.plainText, "recent")
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
        XCTAssertEqual(service.recordedSearchRequests[1].limit, 50)
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
        XCTAssertEqual(service.recordedSearchRequests[1].limit, 50)
        XCTAssertEqual(viewModel.searchCoverage, .recentOnly(limit: 2000))
    }
}
