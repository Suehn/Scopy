import XCTest
@testable import ScopyKit

@MainActor
final class SearchSnapshotConsistencyTests: XCTestCase {
    private var directory: URL!
    private var repository: SQLiteClipboardRepository!
    private var engine: SearchEngineImpl!
    private var dbPath: String { directory.appendingPathComponent("clipboard.db").path }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-search-snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = SQLiteClipboardRepository(dbPath: dbPath)
        try await repository.open()
        engine = SearchEngineImpl(dbPath: dbPath, commitJournal: repository.commitJournal)
        try await engine.open()
    }

    override func tearDown() async throws {
        await engine.close()
        await repository.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func insert(_ text: String, id: UUID = UUID()) async throws -> UUID {
        try await repository.insertItem(
            id: id, type: .text, contentHash: UUID().uuidString, plainText: text, note: nil,
            appBundleID: "com.test.snapshot", createdAt: Date(), lastUsedAt: Date(),
            sizeBytes: text.utf8.count, fileSizeBytes: nil, storageRef: nil, rawData: nil
        )
        return id
    }

    private func fullQuery(_ query: String) -> SearchRequest {
        SearchRequest(query: query, mode: .fuzzy, forceFullFuzzy: true, limit: 100)
    }

    func testRankingHydrationAndSequenceStayInOneReadSnapshot() async throws {
        let id = try await insert("before marker")
        let store = SearchReadStore(dbPath: dbPath)
        try store.open()
        defer { store.close() }
        let before = repository.commitJournal.currentMutationSeq

        try store.withReadSnapshot { mutationSeq in
            let writer = try SQLiteConnection(path: dbPath, flags: SQLiteConnection.openFlags(for: dbPath, readOnly: false))
            defer { writer.close() }
            try writer.execute("BEGIN IMMEDIATE")
            let update = try writer.prepare("UPDATE clipboard_items SET plain_text = ? WHERE id = ?")
            try update.bindText("after marker", at: 1)
            try update.bindText(id.uuidString, at: 2)
            _ = try update.step()
            update.reset()
            try writer.execute("UPDATE scopy_meta SET mutation_seq = mutation_seq + 1 WHERE id = 1")
            try writer.execute("COMMIT")

            let index = try store.buildFullIndex()
            var cache: FullIndexRanker.SortedMatchesCache?
            let page = try FullIndexQuery.execute(
                index: index, shortIndex: nil, readStore: store, request: fullQuery("before"),
                mode: .fuzzy, contentGeneration: 0, cache: &cache, perf: nil
            )
            XCTAssertEqual(mutationSeq, before)
            XCTAssertEqual(page.items.map(\.id), [id])
            XCTAssertEqual(page.items.first?.plainText, "before marker")
            XCTAssertEqual(try store.fetchMutationSeq(), before)
        }
        try store.withReadSnapshot { mutationSeq in
            XCTAssertEqual(mutationSeq, before + 1)
            XCTAssertEqual(try store.fetchItemsByIDs([id]).first?.plainText, "after marker")
        }
    }

    func testDelayedSnapshotsReplayUpsertThenClearWithoutResurrection() async throws {
        let id = try await insert("ab original")
        let full = try XCTUnwrap(SearchReadStore.loadFullIndex(dbPath: dbPath, reserveSlots: 1))
        let short = try XCTUnwrap(SearchReadStore.loadShortQueryIndex(dbPath: dbPath, reserveSlots: 1))
        _ = try await repository.updateItemNoteReturningItem(id: id, note: "ab updated")
        _ = try await repository.deleteAllExceptPinnedReturningStorageRefs()
        await engine.installIndexSnapshotsForTesting(full: full, short: short)

        let result = try await engine.search(request: fullQuery("ab"))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.mutationSeq, repository.commitJournal.currentMutationSeq)
        let shortHealth = await engine.debugShortQueryIndexStats()
        let fullHealth = await engine.debugFullIndexHealth()
        XCTAssertEqual(shortHealth.live, 0)
        XCTAssertEqual(fullHealth.slots - fullHealth.tombstones, 0)
    }

    func testDelayedSnapshotsReplayDeleteThenSameIDInsertAndLatestNote() async throws {
        let id = try await insert("ab original")
        let full = try XCTUnwrap(SearchReadStore.loadFullIndex(dbPath: dbPath, reserveSlots: 1))
        let short = try XCTUnwrap(SearchReadStore.loadShortQueryIndex(dbPath: dbPath, reserveSlots: 1))
        _ = try await repository.deleteItem(id: id, expectedUseCount: 1)
        _ = try await insert("ab replacement", id: id)
        _ = try await repository.updateItemNoteReturningItem(id: id, note: "discarded")
        _ = try await repository.updateItemNoteReturningItem(id: id, note: "latest")
        await engine.installIndexSnapshotsForTesting(full: full, short: short)

        let result = try await engine.search(request: fullQuery("latest"))
        XCTAssertEqual(result.items.map(\.id), [id])
        XCTAssertEqual(result.items.first?.plainText, "ab replacement")
        XCTAssertEqual(result.items.first?.note, "latest")
        XCTAssertEqual(result.mutationSeq, repository.commitJournal.currentMutationSeq)
        let shortHealth = await engine.debugShortQueryIndexStats()
        XCTAssertEqual(shortHealth.live, 1)
    }

    func testOversizedCommitCompletesSnapshotSearchAndClearInRunningEngine() async throws {
        _ = try await insert("anchor")
        let initial = try await engine.search(request: fullQuery("anchor"))
        let initialHealth = await engine.debugFullIndexHealth()
        XCTAssertTrue(initialHealth.isBuilt)
        let largeText = "needle " + String(repeating: "x", count: 8_650_772 - 7)
        let id = try await insert(largeText)
        switch repository.commitJournal.read(after: initial.mutationSeq) {
        case .resnapshotRequired: break
        case .changes: XCTFail("The oversized committed row must exceed the journal byte budget")
        }

        let result = try await engine.search(request: fullQuery("needle"))
        XCTAssertEqual(result.items.map(\.id), [id])
        XCTAssertEqual(result.items.first?.plainText.utf8.count, 8_650_772)
        XCTAssertEqual(result.mutationSeq, repository.commitJournal.currentMutationSeq)
        XCTAssertEqual(result.coverage, .complete)
        let afterGap = await engine.debugFullIndexHealth()
        XCTAssertFalse(afterGap.isBuilt, "The finite snapshot query must not install an old index as current")

        let recent = try await engine.search(request: SearchRequest(query: "", mode: .exact))
        XCTAssertEqual(Set(recent.items.map(\.id)), Set(result.items.map(\.id)).union(initial.items.map(\.id)))
        _ = try await repository.deleteAllExceptPinnedReturningStorageRefs()
        let cleared = try await engine.search(request: fullQuery("needle"))
        XCTAssertTrue(cleared.items.isEmpty)
        XCTAssertEqual(cleared.mutationSeq, repository.commitJournal.currentMutationSeq)
    }

    func testReadOnlyEngineResnapshotsExternalWritesWithoutJournal() async throws {
        let id = try await insert("old marker")
        let reader = SearchEngineImpl(dbPath: dbPath)
        _ = try await reader.search(request: fullQuery("old"))
        _ = try await repository.updateItemNoteReturningItem(id: id, note: "newword")
        let result = try await reader.search(request: fullQuery("newword"))
        XCTAssertEqual(result.items.map(\.id), [id])
        XCTAssertEqual(result.mutationSeq, repository.commitJournal.currentMutationSeq)
        await reader.close()
    }
}
