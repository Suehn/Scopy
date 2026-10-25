import AppKit
import XCTest
@testable import ScopyKit

private actor DurablePersistenceGate {
    private var paused = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class ClipboardBackendLifecycleTests: XCTestCase {
    func testShutdownJoinsDurableWriteAndNextBackendReplaysItExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-ingest-shutdown-\(UUID().uuidString)", isDirectory: true)
        let spool = directory.appendingPathComponent("ingest", isDirectory: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardMonitor(pasteboard: pasteboard, pollingInterval: 60, ingestSpoolDirectory: spool)
        let gate = DurablePersistenceGate()
        monitor.beforeDurablePersistenceForTesting = { await gate.pause() }
        monitor.startMonitoring()
        let text = String(repeating: "durable capture at shutdown ", count: 4_000) + "end"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))

        let capture = Task { await monitor.checkClipboard() }
        await gate.waitUntilPaused()
        var didStop = false
        let shutdown = Task {
            await monitor.stopAndWait()
            didStop = true
        }
        await waitForConditionAsync(timeout: 2, pollInterval: 0.01) {
            monitor.isShuttingDownForTesting
        }
        XCTAssertFalse(didStop, "An in-flight durable write still owns the spool")
        await gate.release()
        await capture.value
        await shutdown.value

        let pending = IngestSpool.discoverPendingEnvelopeURLs(in: spool)
        XCTAssertEqual(pending.count, 1)
        let envelope = try IngestSpool.loadValidatedEnvelope(
            from: XCTUnwrap(pending.first), ingestDirectory: spool, suffix: IngestSpool.pendingEnvelopeSuffix
        )
        XCTAssertEqual(envelope.plainText, text)

        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let settingsStore = SettingsStore(suiteName: directory.appendingPathComponent("settings").path)
        await settingsStore.save(.default)
        let backend = ClipboardBackend(
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 60
        )
        try await backend.start()
        await waitForConditionAsync(timeout: 3, pollInterval: 0.01) {
            let items = try? await backend.fetchRecent(limit: 10, offset: 0)
            return items?.count == 1 && IngestSpool.discoverPendingEnvelopeURLs(in: spool).isEmpty
        }
        await backend.stop()

        let verifier = StorageService(databasePath: databasePath)
        try await verifier.open()
        let stored = try await verifier.fetchRecent(limit: 10, offset: 0)
        let receipts = try await verifier.repository.ingestReceiptCount()
        await verifier.close()
        XCTAssertEqual(stored.map(\.plainText), [text])
        XCTAssertEqual(stored.first?.useCount, 1)
        XCTAssertEqual(receipts, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: spool.path).isEmpty)
    }
}
