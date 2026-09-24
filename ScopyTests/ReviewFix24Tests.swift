import AppKit
import XCTest
@testable import ScopyKit

@MainActor
final class StorageDeletionConcurrencyTests: XCTestCase {

    func testDeleteAllExceptPinnedDoesNotBlockMainActorAndIsBounded() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-clearall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
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
        let fileOps = StorageService.StorageFileOps(removeFile: { url in
            counter.increment()

            usleep(50_000) // 50ms
            try? FileManager.default.removeItem(at: url)

            counter.decrement()
        })

        let storage = StorageService(databasePath: dbPath, fileOps: fileOps)
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
