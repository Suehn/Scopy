import XCTest
@testable import ScopyKit

/// Concurrency safety of searches, cache refreshes, and task cancellation.
@MainActor
final class ConcurrencyTests: XCTestCase {
    var storage: StorageService!
    var search: SearchEngineImpl!

    override func setUp() async throws {
        storage = StorageService(databasePath: Self.makeSharedInMemoryDatabasePath())
        try await storage.open()
        search = SearchEngineImpl(dbPath: storage.databaseFilePath)
        try await search.open()
    }

    override func tearDown() async throws {
        await search.close()
        await storage.close()
        storage = nil
        search = nil
    }

    // MARK: - Search Cancellation Safety

    /// Rapid successive searches cancel safely.
    func testSearchCancellationSafety() async throws {
        // Insert test data.
        for i in 0..<100 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Test item \(i) with some content",
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "hash_\(i)",
                sizeBytes: 50
            )
            _ = try await storage.upsertItem(content)
        }

        // Fire several searches in quick succession.
        let search = self.search!
        var tasks: [Task<SearchEngineImpl.SearchResult?, Never>] = []
        for i in 0..<10 {
            let task = Task {
                let request = SearchRequest(
                    query: "item \(i)",
                    mode: .fuzzy,
                    appFilter: nil,
                    typeFilter: nil,
                    limit: 50,
                    offset: 0
                )
                return try? await search.search(request: request)
            }
            tasks.append(task)
        }

        // Cancel the earlier ones.
        for i in 0..<5 {
            tasks[i].cancel()
        }

        // Wait for every task.
        var completedCount = 0
        for task in tasks {
            let result = await task.value
            if result != nil {
                completedCount += 1
            }
        }

        // At least the later searches complete.
        XCTAssertGreaterThanOrEqual(completedCount, 1, "At least some searches should complete")
    }

    // MARK: - Cache Refresh Concurrency

    /// Cache refreshes are concurrency-safe.
    func testCacheRefreshConcurrency() async throws {
        // Insert test data.
        for i in 0..<50 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Cache test \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "cache_hash_\(i)",
                sizeBytes: 20
            )
            _ = try await storage.upsertItem(content)
        }

        // Run several short queries in sequence (they refresh the cache).
        var results: [SearchEngineImpl.SearchResult] = []
        for i in 0..<20 {
            let request = SearchRequest(
                query: String(i % 10), // A short query exercises the cache.
                mode: .exact,
                appFilter: nil,
                typeFilter: nil,
                limit: 10,
                offset: 0
            )
            if let result = try? await search.search(request: request) {
                results.append(result)
            }
        }

        // Every search completes.
        XCTAssertEqual(results.count, 20, "All searches should complete")
    }

    // MARK: - Sequential Insert and Search

    // MARK: - Deduplication

    // MARK: - Search Version Number

    /// The search version keeps an older result from replacing a newer one.
    func testSearchVersionPreventsStaleResults() async throws {
        let service = TestMockClipboardService()
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }

        service.setItemCount(200)
        await appState.load()
        service.resetSearchCallCount()
        service.searchDelayIgnoresCancellation = true

        // Make the first query slower, so it completes after the second query.
        service.searchDelayNsByQuery["1"] = 500_000_000
        service.searchDelayNsByQuery["2"] = 0

        appState.searchQuery = "1"
        appState.search()

        await assertEventually(timeout: 2.0, pollInterval: 0.01, {
            service.searchStartedQueries.contains("1")
        }, message: "Slow search should start before the newer search cancels the task")

        appState.searchQuery = "2"
        appState.search()

        // Fast search should win first.
        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.searchCallCount == 1 &&
            service.lastSearchQuery == "2" &&
            !appState.items.isEmpty
        }, message: "Fast search should complete first")
        XCTAssertTrue(appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("2") })

        // Slow search completes later, but should not overwrite the latest results.
        await assertEventually(timeout: 2.0, pollInterval: 0.01, {
            service.searchCallCount == 2
        }, message: "Slow search should eventually complete")
        XCTAssertTrue(appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("2") })
    }

    /// An older plain load does not replace a later search's result.
    func testLoadDoesNotOverwriteNewerSearchResults() async throws {
        let service = TestMockClipboardService()
        let appState = AppState.forTesting(service: service)
        defer { appState.stop() }

        service.setItemCount(200)
        service.fetchRecentDelayNs = 120_000_000

        let loadTask = Task { await appState.load() }
        try await Task.sleep(nanoseconds: 10_000_000)

        appState.searchQuery = "199"
        appState.search()

        await assertEventually(timeout: 1.0, pollInterval: 0.01, {
            service.lastSearchQuery == "199" &&
            appState.items.count == 1 &&
            appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("199") } &&
            !appState.isLoading
        }, message: "Newer search should complete before the delayed load returns")

        await loadTask.value

        XCTAssertEqual(appState.items.count, 1)
        XCTAssertTrue(appState.items.allSatisfy { $0.plainText.localizedCaseInsensitiveContains("199") })
        XCTAssertEqual(appState.totalCount, 1)
        XCTAssertFalse(appState.canLoadMore)
        XCTAssertFalse(appState.isLoading)
    }

    // MARK: - v0.11 Concurrent Search Stress Tests

    /// Stress: ten concurrent searches.
    func testConcurrentSearchStress() async throws {
        // Insert a larger data set.
        for i in 0..<1000 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Stress test item \(i) with lorem ipsum dolor sit amet",
                payload: .none,
                appBundleID: "com.test.stress",
                contentHash: "stress_hash_\(i)",
                sizeBytes: 60
            )
            _ = try await storage.upsertItem(content)
        }

        // A task group runs the searches concurrently.
        let search = self.search!
        let queries = ["stress", "lorem", "ipsum", "dolor", "amet", "test", "item", "sit", "content", "hash"]

        await withTaskGroup(of: SearchEngineImpl.SearchResult?.self) { group in
            for query in queries {
                group.addTask {
                    let request = SearchRequest(
                        query: query,
                        mode: .fuzzy,
                        appFilter: nil,
                        typeFilter: nil,
                        limit: 50,
                        offset: 0
                    )
                    return try? await search.search(request: request)
                }
            }

            var successCount = 0
            var totalItems = 0
            for await result in group {
                if let result = result {
                    successCount += 1
                    totalItems += result.items.count
                }
            }

            // Every search completes.
            XCTAssertEqual(successCount, queries.count, "All concurrent searches should complete")
            XCTAssertGreaterThan(totalItems, 0, "Should return some results")
        }
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }
}
