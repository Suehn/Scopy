import XCTest
@testable import ScopyKit

/// Timers, tasks, event streams, and database connections are released correctly.
@MainActor
final class ResourceCleanupTests: XCTestCase {

    // MARK: - Storage Cleanup Tests

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
            // Expected
        }
    }

    /// A consumer owns cancellation; stopping the service need not finish its event stream.
    func testEventStreamCleanup() async throws {
        let service = ClipboardServiceFactory.create(databasePath: Self.makeSharedInMemoryDatabasePath())

        // Start the service.
        try await service.start()

        // A task that listens for events.
        let eventTask = Task {
            var eventCount = 0
            for await _ in service.eventStream {
                eventCount += 1
                if eventCount >= 1 {
                    break
                }
            }
            return eventCount
        }

        // Give the listener a chance to subscribe.
        await Task.yield()

        // Stop the service and wait for its cleanup.
        await service.stopAndWait()

        // Cancel the event task.
        eventTask.cancel()

        // The task finishes.
        let _ = await eventTask.value
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }

    // MARK: - Task Cancellation Tests

}
