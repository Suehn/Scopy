import XCTest
import ScopyKit
@testable import Scopy

/// Older load and search results cannot replace a newer history query.
@MainActor
final class ConcurrencyTests: XCTestCase {
    /// The search version keeps an older result from replacing a newer one.
    func testSearchVersionPreventsStaleResults() async throws {
        let service = TestMockClipboardService()
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.tests)
        defer { viewModel.stop() }

        service.setItemCount(200)
        await viewModel.load()
        service.resetSearchCallCount()

        for query in ["T", "Te", "Test item 2"] {
            viewModel.searchQuery = query
            viewModel.search()
        }
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 1 && !viewModel.isLoading
        }, message: "Unstarted queries should coalesce into the latest input")
        let coalescedIDs = (0..<200).filter { "Test item \($0)".contains("Test item 2") }
            .map { service.itemID(at: $0) }
        XCTAssertEqual(viewModel.items.map(\.id), coalescedIDs)
        service.resetSearchCallCount()
        service.searchDelayIgnoresCancellation = true
        let expectedIDs = (0..<200).filter { "Test item \($0)".contains("2") }
            .map { service.itemID(at: $0) }

        // Make the first query slower, so it completes after the second query.
        service.searchDelayNsByQuery["1"] = 500_000_000
        service.searchDelayNsByQuery["2"] = 0

        viewModel.searchQuery = "1"
        viewModel.search()

        await assertEventually(timeout: 2.0, pollInterval: 0.01, {
            service.searchStartedQueries.contains("1")
        }, message: "Slow search should start before the newer search cancels the task")

        viewModel.searchQuery = "2"
        viewModel.search()

        // Fast search should win first.
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 1 &&
            service.lastSearchQuery == "2" &&
            !viewModel.items.isEmpty
        }, message: "Fast search should complete first")
        XCTAssertEqual(viewModel.items.map(\.id), expectedIDs)

        // Slow search completes later, but should not overwrite the latest results.
        await assertEventually(timeout: 2.0, pollInterval: 0.01, {
            service.searchCallCount == 2
        }, message: "Slow search should eventually complete")
        await Task.yield()
        XCTAssertEqual(viewModel.items.map(\.id), expectedIDs)
    }

    /// An older plain load does not replace a later search's result.
    func testLoadDoesNotOverwriteNewerSearchResults() async throws {
        let service = TestMockClipboardService()
        let viewModel = HistoryViewModel(service: service, settingsViewModel: SettingsViewModel(service: service))
        viewModel.configureTiming(.tests)
        defer { viewModel.stop() }

        service.setItemCount(200)
        service.fetchRecentDelayNs = 120_000_000

        let loadTask = Task { await viewModel.load() }
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.historyPageFetchCallCount == 1
        }, message: "The plain load must start before the newer query")

        viewModel.searchQuery = "199"
        viewModel.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.lastSearchQuery == "199" &&
            viewModel.items.count == 1 &&
            viewModel.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("199") } &&
            !viewModel.isLoading
        }, message: "Newer search should complete before the delayed load returns")

        await loadTask.value

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertTrue(viewModel.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("199") })
        XCTAssertEqual(viewModel.totalCount, 1)
        XCTAssertFalse(viewModel.canLoadMore)
        XCTAssertFalse(viewModel.isLoading)
    }

}
