import XCTest
@testable import ScopyKit

@MainActor
final class KnownDataVersionExternalWriteTests: XCTestCase {

    func testInternalMutationDoesNotSwallowUnobservedExternalCommits() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-known-dataversion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()

        func makeTextContent(_ text: String) -> ClipboardMonitor.ClipboardContent {
            ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: text,
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "\(text)-\(UUID().uuidString)",
                sizeBytes: text.utf8.count
            )
        }

        let apple = try await storage.upsertItem(makeTextContent("apple"))

        let search = SearchEngineImpl(dbPath: dbPath)
        try await search.open()

        _ = try await search.search(request: SearchRequest(query: "apple", mode: .fuzzy, limit: 10, offset: 0))
        #if DEBUG
        let health = await search.debugFullIndexHealth()
        XCTAssertTrue(health.isBuilt)
        #endif

        // Simulate an "external" DB write (or a missed callback): write via storage, but don't call
        // search.handleUpsertedItem for the new row.
        let banana = try await storage.upsertItem(makeTextContent("banana"))

        // Now perform a normal internal mutation that *does* notify SearchEngineImpl. If SearchEngineImpl
        // blindly refreshes knownDataVersion here, it can swallow the prior unobserved commit and keep a
        // stale in-memory full index (missing "banana").
        let cherry = try await storage.upsertItem(makeTextContent("cherry"))
        await search.handleUpsertedItem(cherry)

        let result = try await search.search(request: SearchRequest(query: "banana", mode: .fuzzy, limit: 10, offset: 0))
        XCTAssertTrue(result.items.contains { $0.id == banana.id })

        // Make sure the existing item is still searchable too (basic sanity).
        let sanity = try await search.search(request: SearchRequest(query: "apple", mode: .fuzzy, limit: 10, offset: 0))
        XCTAssertTrue(sanity.items.contains { $0.id == apple.id })

        await search.close()
        await storage.close()
    }
}
