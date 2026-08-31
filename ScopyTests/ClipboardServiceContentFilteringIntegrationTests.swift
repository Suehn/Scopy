import AppKit
import XCTest
import ScopyKit

@MainActor
final class ClipboardServiceContentFilteringIntegrationTests: XCTestCase {

    private var service: (any ClipboardServiceProtocol)?
    private var tempDirectory: URL!
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!
    private var settingsSuiteName: String!

    override func setUp() async throws {
        settingsSuiteName = "scopy-content-filtering-integration-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName)
        settingsStore = SettingsStore(suiteName: settingsSuiteName)
        pasteboard = NSPasteboard.withUniqueName()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-content-filtering-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let service {
            await service.stopAndWait()
        }
        try? FileManager.default.removeItem(at: tempDirectory)
        UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName)

        service = nil
        tempDirectory = nil
        pasteboard = nil
        settingsStore = nil
        settingsSuiteName = nil
    }

    func testSaveImagesDisabledSkipsImageHistoryAndCleansPendingIngestArtifacts() async throws {
        try await startService { settings in
            settings.saveImages = false
        }

        let imageData = try TestFixture.data("history-replay-real-screenshot-paletted.png")
        let sentinel = "image-filter-sentinel-\(UUID().uuidString)"
        let changeJumpBaseline = await ClipboardIngestMetrics.shared.getSummary().changeJumpCount

        pasteboard.clearContents()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        await waitForMonitorRead(afterChangeJumpCount: changeJumpBaseline)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(sentinel, forType: .string))
        await waitForHistoryItem(plainText: sentinel)

        let items = try await XCTUnwrap(service).fetchRecent(limit: 20, offset: 0)
        XCTAssertTrue(items.contains { $0.type == .text && $0.plainText == sentinel })
        XCTAssertFalse(items.contains { $0.type == .image })

        let ingestDirectory = tempDirectory.appendingPathComponent("ingest", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingestDirectory.path))
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.01) {
            (try? Self.pendingIngestArtifactNames(in: ingestDirectory).isEmpty) ?? false
        }
        XCTAssertEqual(try Self.pendingIngestArtifactNames(in: ingestDirectory), [])
    }

    func testSaveFilesDisabledSkipsFileHistory() async throws {
        try await startService { settings in
            settings.saveFiles = false
        }

        let fileURL = tempDirectory.appendingPathComponent("blocked-\(UUID().uuidString).txt")
        try Data("blocked file payload".utf8).write(to: fileURL)
        let sentinel = "file-filter-sentinel-\(UUID().uuidString)"
        let changeJumpBaseline = await ClipboardIngestMetrics.shared.getSummary().changeJumpCount

        pasteboard.clearContents()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        await waitForMonitorRead(afterChangeJumpCount: changeJumpBaseline)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(sentinel, forType: .string))
        await waitForHistoryItem(plainText: sentinel)

        let items = try await XCTUnwrap(service).fetchRecent(limit: 20, offset: 0)
        XCTAssertTrue(items.contains { $0.type == .text && $0.plainText == sentinel })
        XCTAssertFalse(items.contains { $0.type == .file })
    }

    private func startService(updateSettings: (inout SettingsDTO) -> Void) async throws {
        var settings = await settingsStore.load()
        updateSettings(&settings)
        await settingsStore.save(settings)

        let service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: tempDirectory.appendingPathComponent("clipboard.db").path,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.1
        )
        self.service = service
        try await service.start()
    }

    private func waitForMonitorRead(afterChangeJumpCount baseline: Int) async {
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.01) {
            let summary = await ClipboardIngestMetrics.shared.getSummary()
            return summary.changeJumpCount > baseline
        }
    }

    private func waitForHistoryItem(plainText: String) async {
        await waitForConditionAsync(timeout: 2.0, pollInterval: 0.01) { [service] in
            guard let service else { return false }
            let items = try? await service.fetchRecent(limit: 20, offset: 0)
            return items?.contains { $0.type == .text && $0.plainText == plainText } ?? false
        }
    }

    nonisolated private static func pendingIngestArtifactNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter {
                $0.hasSuffix(".envelope.json")
                    || $0.hasSuffix(".envelope.acked")
                    || $0.hasSuffix(".payload")
                    || $0.hasPrefix(".ingest-work-")
            }
            .sorted()
    }
}
