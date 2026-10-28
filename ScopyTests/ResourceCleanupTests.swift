import XCTest
@testable import ScopyKit

/// Closing storage releases its database connection.
@MainActor
final class ResourceCleanupTests: XCTestCase {

    /// The database connection is released on close.
    func testDatabaseConnectionCleanup() async throws {
        let storage = StorageService(databasePath: ":memory:")
        try await storage.open()

        // Insert some data.
        let content = ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: "Test content",
            payload: .none,
            appBundleID: nil,
            contentHash: "test_hash",
            sizeBytes: 12
        )
        _ = try await storage.upsertItem(content)

        // Close the database.
        await storage.close()

        // Later database calls fail once it is closed.
        do {
            _ = try await storage.getItemCount()
            XCTFail("Expected databaseNotOpen after close")
        } catch {
            guard case SQLiteClipboardRepository.RepositoryError.databaseNotOpen = error else {
                return XCTFail("Expected databaseNotOpen after close, received \(error)")
            }
        }
    }

}
