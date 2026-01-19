import AppKit
import XCTest
@testable import ScopyKit

@MainActor
final class IndexLifecycleTests: XCTestCase {

    func testFullFuzzyIndexMarksStaleAfterTombstonesAndRebuilds() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: dbPath)
        try await storage.open()

        for i in 0..<64 {
            let text = "item \(i)"
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: text,
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "hash-\(i)-\(UUID().uuidString)",
                sizeBytes: text.utf8.count
            )
            _ = try await storage.upsertItem(content)
        }

        let search = SearchEngineImpl(dbPath: dbPath)
        try await search.open()

        _ = try await search.search(request: SearchRequest(query: "item", mode: .fuzzy, limit: 10, offset: 0))
        var health = await search.debugFullIndexHealth()
        XCTAssertTrue(health.isBuilt)
        XCTAssertFalse(health.isStale)
        XCTAssertEqual(health.tombstones, 0)
        XCTAssertEqual(health.slots, 64)

        let toDelete = try await storage.fetchRecent(limit: 16, offset: 0)
        for item in toDelete {
            try await storage.deleteItem(item.id)
            await search.handleDeletion(id: item.id)
        }

        health = await search.debugFullIndexHealth()
        XCTAssertTrue(health.isBuilt)
        if !health.isStale {
            // Depending on timing, background rebuild may already complete.
            XCTAssertEqual(health.tombstones, 0)
            XCTAssertEqual(health.slots, 48)
        }

        _ = try await search.search(request: SearchRequest(query: "item", mode: .fuzzy, limit: 10, offset: 0))
        health = await search.debugFullIndexHealth()
        XCTAssertTrue(health.isBuilt)
        XCTAssertFalse(health.isStale)
        XCTAssertEqual(health.tombstones, 0)
        XCTAssertEqual(health.slots, 48)

        await search.close()
        await storage.close()
        try? FileManager.default.removeItem(at: baseURL)
    }
}

@MainActor
final class StorageDeletionConcurrencyTests: XCTestCase {

    func testDeleteAllExceptPinnedDoesNotBlockMainActorAndIsBounded() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-clearall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: dbPath)
        try await storage.open()

        let payload = Data(repeating: 0xB, count: ScopyThresholds.externalStorageBytes)
        for i in 0..<40 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .image,
                plainText: "large \(i)",
                payload: .data(payload),
                appBundleID: "com.test.app",
                contentHash: "large-\(i)-\(UUID().uuidString)",
                sizeBytes: payload.count
            )
            _ = try await storage.upsertItem(content)
        }

        final class InFlightCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var inFlight = 0
            private var maxInFlight = 0

            func increment() {
                lock.lock()
                inFlight += 1
                if inFlight > maxInFlight {
                    maxInFlight = inFlight
                }
                lock.unlock()
            }

            func decrement() {
                lock.lock()
                inFlight -= 1
                lock.unlock()
            }

            var max: Int {
                lock.lock()
                let value = maxInFlight
                lock.unlock()
                return value
            }
        }

        let counter = InFlightCounter()

        let originalRemover = StorageService.fileRemoverForTesting
        StorageService.fileRemoverForTesting = { url in
            counter.increment()

            usleep(50_000) // 50ms
            try? FileManager.default.removeItem(at: url)

            counter.decrement()
        }
        defer { StorageService.fileRemoverForTesting = originalRemover }

        let tick = expectation(description: "Main actor remains responsive")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            tick.fulfill()
        }

        let deletion = Task {
            try await storage.deleteAllExceptPinned()
        }

        await fulfillment(of: [tick], timeout: 1.0)
        _ = try await deletion.value

        XCTAssertLessThanOrEqual(counter.max, StorageService.maxConcurrentFileDeletions)

        let remaining = try await storage.fetchRecent(limit: 10, offset: 0)
        XCTAssertTrue(remaining.allSatisfy(\.isPinned))

        await storage.close()
        try? FileManager.default.removeItem(at: baseURL)
    }
}

final class ClipboardServiceStartAtomicityTests: XCTestCase {

    func testStartFailureDoesNotPoisonServiceAndIsRetryable() async throws {
        let invalidDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-start-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDBURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: invalidDBURL) }

        let suiteName = "scopy-start-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(suiteName: suiteName)
        let pasteboard = NSPasteboard.withUniqueName()
        let service = ClipboardService(
            databasePath: invalidDBURL.path,
            settingsStore: store,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.1
        )

        do {
            try await service.start()
            XCTFail("Expected start() to throw for invalid database path")
        } catch { }

        do {
            try await service.start()
            XCTFail("Expected start() to throw again (retryable) for invalid database path")
        } catch { }
    }
}
