import XCTest
@testable import ScopyKit

@MainActor
final class SearchBackendConsistencyTests: XCTestCase {

    func testClipboardServiceProvidesEvidenceForEverySearchModeAndNoteOnlyMatches() async throws {
        let dbPath = Self.makeSharedInMemoryDatabasePath()
        let seedStorage = StorageService(databasePath: dbPath)
        try await seedStorage.open()
        defer { Task { @MainActor in await seedStorage.close() } }

        let stored = try await seedStorage.upsertItem(
            TestDataFactory.makeTextContent("run command with needle here, then needle again; foo bar")
        )
        _ = try await seedStorage.updateNote(
            id: stored.id,
            note: "beta and remarktoken live only in this note"
        )

        let service = ClipboardServiceFactory.create(useMock: false, databasePath: dbPath)
        try await service.start()
        defer { Task { @MainActor in await service.stopAndWait() } }

        let requests = [
            SearchRequest(query: "needle", mode: .exact, limit: 10, offset: 0),
            SearchRequest(query: "cmd", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0),
            SearchRequest(query: "command beta", mode: .fuzzyPlus, forceFullFuzzy: true, limit: 10, offset: 0),
            SearchRequest(query: #"needle"#, mode: .regex, limit: 10, offset: 0),
            SearchRequest(query: "foo_bar", mode: .exact, limit: 10, offset: 0),
            SearchRequest(query: "remarktoken", mode: .exact, limit: 10, offset: 0)
        ]

        for request in requests {
            let page = try await service.search(query: request)
            XCTAssertFalse(page.hits.isEmpty, "Expected a result for \(request.mode.rawValue)")
            XCTAssertTrue(
                page.hits.allSatisfy { $0.matchContext != nil },
                "Every \(request.mode.rawValue) candidate must explain why it matched"
            )
        }

        let noteOnly = try await service.search(
            query: SearchRequest(query: "remarktoken", mode: .exact, limit: 10, offset: 0)
        )
        XCTAssertEqual(noteOnly.hits.first?.matchContext?.fragments.map(\.source), [.note])
    }

    func testClipboardServiceRetainsHitWithoutEvidenceWhenFuzzyMatchersDisagree() async throws {
        let dbPath = Self.makeSharedInMemoryDatabasePath()
        let seedStorage = StorageService(databasePath: dbPath)
        try await seedStorage.open()
        defer { Task { @MainActor in await seedStorage.close() } }

        let problemHit = try await seedStorage.upsertItem(
            TestDataFactory.makeTextContent("/Users/example/Cafe\u{301}.txt")
        )
        let normalHit = try await seedStorage.upsertItem(
            TestDataFactory.makeTextContent("/Users/example/Cafe.txt")
        )

        let service = ClipboardServiceFactory.create(useMock: false, databasePath: dbPath)
        try await service.start()
        defer { Task { @MainActor in await service.stopAndWait() } }

        let page = try await service.search(
            query: SearchRequest(
                query: "cafe",
                mode: .fuzzy,
                forceFullFuzzy: true,
                limit: 10,
                offset: 0
            )
        )

        XCTAssertEqual(Set(page.hits.map(\.item.id)), [problemHit.id, normalHit.id])
        XCTAssertNil(page.hits.first { $0.item.id == problemHit.id }?.matchContext)
        XCTAssertNotNil(page.hits.first { $0.item.id == normalHit.id }?.matchContext)
    }

    func testPinnedChangeInvalidatesShortQueryCacheThroughClipboardService() async throws {
        let dbPath = Self.makeSharedInMemoryDatabasePath()

        let seedStorage = StorageService(databasePath: dbPath)
        try await seedStorage.open()
        defer { Task { @MainActor in await seedStorage.close() } }

        let older = try await seedStorage.upsertItem(TestDataFactory.makeTextContent("Apple One"))
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms delay for ordering
        let newer = try await seedStorage.upsertItem(TestDataFactory.makeTextContent("Apple Two"))

        let service = ClipboardServiceFactory.create(useMock: false, databasePath: dbPath)
        try await service.start()
        defer { Task { @MainActor in await service.stopAndWait() } }

        let before = try await service.search(query: SearchRequest(query: "a", mode: .exact, limit: 50, offset: 0))
        XCTAssertEqual(before.hits.first?.item.id, newer.id)
        XCTAssertNotNil(before.hits.first?.matchContext)

        try await service.pin(itemID: older.id)

        let after = try await service.search(query: SearchRequest(query: "a", mode: .exact, limit: 50, offset: 0))
        XCTAssertEqual(after.hits.first?.item.id, older.id)
        XCTAssertNotNil(after.hits.first?.matchContext)
    }

    func testZeroWidthRegexKeepsEmptyImageCandidateExplainable() async throws {
        let dbPath = Self.makeSharedInMemoryDatabasePath()
        let seedStorage = StorageService(databasePath: dbPath)
        try await seedStorage.open()
        defer { Task { @MainActor in await seedStorage.close() } }

        let image = try await seedStorage.upsertItem(TestDataFactory.makeImageContent())
        let service = ClipboardServiceFactory.create(useMock: false, databasePath: dbPath)
        try await service.start()
        defer { Task { @MainActor in await service.stopAndWait() } }

        let page = try await service.search(
            query: SearchRequest(query: "^", mode: .regex, limit: 10, offset: 0)
        )
        let imageHit = try XCTUnwrap(page.hits.first { $0.item.id == image.id })
        let context = try XCTUnwrap(imageHit.matchContext)

        XCTAssertTrue(context.isPositionOnly)
        XCTAssertEqual(context.fragments.map(\.text), ["（空内容）"])
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }
}
