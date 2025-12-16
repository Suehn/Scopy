import XCTest
import ScopyKit

@MainActor
final class SearchBackendConsistencyTests: XCTestCase {

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
        XCTAssertEqual(before.items.first?.id, newer.id)

        try await service.pin(itemID: older.id)

        let after = try await service.search(query: SearchRequest(query: "a", mode: .exact, limit: 50, offset: 0))
        XCTAssertEqual(after.items.first?.id, older.id)
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }
}
