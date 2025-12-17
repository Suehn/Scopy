import AppKit
import XCTest
import ScopyKit

@MainActor
final class StorageStatsSemanticsTests: XCTestCase {

    func testStorageStatsAreContentEstimateWhileDetailedStatsIncludeDiskOverhead() async {
        let suiteName = "scopy-stats-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let settingsStore = SettingsStore(suiteName: suiteName)
        let pasteboard = NSPasteboard.withUniqueName()

        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-stats-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create temp directory: \(error)")
            return
        }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.2
        )

        do {
            try await service.start()

            // Add a small orphan file to the thumbnail directory so detailed stats must exceed content estimate.
            let orphan = baseURL
                .appendingPathComponent("thumbnails", isDirectory: true)
                .appendingPathComponent("orphan.bin")
            do {
                try Data(repeating: 0xAA, count: 1024).write(to: orphan)
            } catch {
                XCTFail("Failed to write orphan file: \(error)")
                return
            }

            do {
                let stats = try await service.getStorageStats()
                XCTAssertEqual(stats.itemCount, 0)
                XCTAssertEqual(stats.sizeBytes, 0, "Content estimate should be 0 for empty history")

                let detailed = try await service.getDetailedStorageStats()
                XCTAssertGreaterThan(detailed.totalSizeBytes, 0)
                XCTAssertGreaterThan(detailed.totalSizeBytes, stats.sizeBytes)
            } catch {
                XCTFail("Failed to fetch storage stats: \(error)")
            }
        } catch {
            XCTFail("Failed to start service: \(error)")
        }

        await service.stopAndWait()
        try? FileManager.default.removeItem(at: baseURL)
    }
}
