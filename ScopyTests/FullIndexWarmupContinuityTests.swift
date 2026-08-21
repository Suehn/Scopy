import XCTest
@testable import ScopyKit

/// The full index is independent of the query, so typing must keep one interactive warm-up
/// build running instead of cancel/restarting it per keystroke (which starved the build and
/// forced repeated full-table scans on heavy corpora).
@MainActor
final class FullIndexWarmupContinuityTests: XCTestCase {
    func testTypingDifferentQueriesKeepsOneInteractiveWarmupBuild() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-warmup-continuity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            // ≥ 2000 items qualifies the corpus for background warm-up; one long item makes it
            // "heavy" so fuzzy queries take the staged interactive path that triggers warm-up.
            for i in 0..<2_050 {
                try await upsertText(storage: storage, text: "warm item \(i)")
            }
            try await upsertText(storage: storage, text: String(repeating: "x", count: 120_000))

            let search = SearchEngineImpl(dbPath: dbPath)
            try await search.open()
            do {
                _ = try await search.search(
                    request: SearchRequest(query: "warm", mode: .fuzzy, limit: 50, offset: 0)
                )
                let generationAfterFirstQuery = await search.debugFullIndexBuildGeneration()
                XCTAssertGreaterThan(
                    generationAfterFirstQuery, 0,
                    "First interactive fuzzy query must start the warm-up build"
                )

                _ = try await search.search(
                    request: SearchRequest(query: "warmi", mode: .fuzzy, limit: 50, offset: 0)
                )
                _ = try await search.search(
                    request: SearchRequest(query: "warmit", mode: .fuzzy, limit: 50, offset: 0)
                )
                let generationAfterTyping = await search.debugFullIndexBuildGeneration()
                XCTAssertEqual(
                    generationAfterTyping, generationAfterFirstQuery,
                    "Typing must reuse the in-flight warm-up build instead of cancel/restarting it"
                )

                await search.debugAwaitFullIndexBuild()
                let health = await search.debugFullIndexHealth()
                XCTAssertTrue(health.isBuilt)
                await search.close()
            } catch {
                await search.close()
                throw error
            }
            await storage.close()
        } catch {
            await storage.close()
            throw error
        }
    }

    private func upsertText(storage: StorageService, text: String) async throws {
        let content = ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            payload: .none,
            appBundleID: "com.test.app",
            contentHash: "hash-\(UUID().uuidString)",
            sizeBytes: text.utf8.count
        )
        _ = try await storage.upsertItem(content)
    }
}
