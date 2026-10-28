import AppKit
import Darwin
import XCTest
@testable import ScopyKit

private actor BackendLifecycleGate {
    private var paused = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !paused else { return }
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
        let gate = BackendLifecycleGate()
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

    func testCommitPublisherPreservesTransactionValuesAndClearWaitsForPublication() async throws {
        let fixture = try await makeHistoryFixture()
        let gate = BackendLifecycleGate()
        await fixture.backend.setHistoryPublicationInterlockForTesting { _ in await gate.pause() }
        let clearDelivered = expectation(description: "clear commit published after both note commits")
        var changes: [CommittedHistoryChange] = []
        let observer = Task {
            for await event in fixture.backend.eventStream {
                guard case .history(let committed) = event else { continue }
                changes.append(committed)
                if case .itemsCleared = committed.change {
                    clearDelivered.fulfill()
                    return
                }
            }
        }
        defer { observer.cancel() }

        try await fixture.backend.updateNote(itemID: fixture.itemID, note: "first committed note")
        await gate.waitUntilPaused()
        try await fixture.backend.updateNote(itemID: fixture.itemID, note: "second committed note")
        let clear = Task { try await fixture.backend.clearAll() }
        await waitForConditionAsync(timeout: 2, pollInterval: 0.01) {
            await fixture.backend.isDrainingHistoryForTesting
        }
        let clearedSnapshot = try await fixture.backend.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertEqual(clearedSnapshot.total, 0)
        XCTAssertTrue(changes.isEmpty, "A paused publisher cannot complete the clear publication barrier")
        await gate.release()
        try await clear.value
        await fulfillment(of: [clearDelivered], timeout: 2)
        await fixture.backend.stop()

        XCTAssertEqual(changes.map(\.mutationSeq), Array((fixture.initialMutationSeq + 1)...(fixture.initialMutationSeq + 3)))
        XCTAssertEqual(changes.map(\.totalCount), [1, 1, 0])
        guard changes.count == 3,
              case .itemsChanged(let first, kind: .content) = changes[0].change,
              case .itemsChanged(let second, kind: .content) = changes[1].change,
              case .itemsCleared(let deletedIDs) = changes[2].change else {
            return XCTFail("Expected the two immutable note commits followed by the exact clear set")
        }
        XCTAssertEqual(first.first?.note, "first committed note")
        XCTAssertEqual(second.first?.note, "second committed note")
        XCTAssertEqual(deletedIDs, [fixture.itemID])
        XCTAssertEqual(changes.last?.mutationSeq, clearedSnapshot.mutationSeq)
    }

    func testSlowPublisherReportsResnapshotWhenItsCommitLogPositionExpires() async throws {
        let fixture = try await makeHistoryFixture()
        let gate = BackendLifecycleGate()
        await fixture.backend.setHistoryPublicationInterlockForTesting { _ in await gate.pause() }
        let gapDelivered = expectation(description: "expired log cursor requests a snapshot")
        var deliveredSequences: [Int64] = []
        var gapSequence: Int64?
        let observer = Task {
            for await event in fixture.backend.eventStream {
                switch event {
                case .history(let committed):
                    deliveredSequences.append(committed.mutationSeq)
                case .historyResnapshotRequired(let mutationSeq):
                    gapSequence = mutationSeq
                    gapDelivered.fulfill()
                    return
                default:
                    continue
                }
            }
        }
        defer { observer.cancel() }

        try await fixture.backend.updateNote(itemID: fixture.itemID, note: "held commit")
        await gate.waitUntilPaused()
        for index in 0...StorageCommitJournal.capacity {
            try await fixture.backend.updateNote(itemID: fixture.itemID, note: "later commit \(index)")
        }
        let snapshot = try await fixture.backend.fetchHistoryPage(limit: 10, after: nil)
        await gate.release()
        await fulfillment(of: [gapDelivered], timeout: 3)
        await fixture.backend.stop()

        XCTAssertEqual(deliveredSequences, [fixture.initialMutationSeq + 1])
        XCTAssertEqual(gapSequence, snapshot.mutationSeq)
        XCTAssertEqual(snapshot.items.first?.note, "later commit \(StorageCommitJournal.capacity)")
    }

    func testOversizedCapturedCommitConvergesWhileBackendIsRunning() async throws {
        let fixture = try await makeHistoryFixture(monitorPollingInterval: 0.01)
        let backend = fixture.backend

        let oversizedPublished = expectation(description: "oversized commit requests a snapshot")
        let clearPublished = expectation(description: "clear remains observable after the journal gap")
        var gapSequence: Int64?
        var clearCommit: CommittedHistoryChange?
        let observer = Task {
            for await event in backend.eventStream {
                switch event {
                case .historyResnapshotRequired(let mutationSeq):
                    gapSequence = mutationSeq
                    oversizedPublished.fulfill()
                case .history(let commit):
                    if case .itemsCleared = commit.change {
                        clearCommit = commit
                        clearPublished.fulfill()
                        return
                    }
                default:
                    break
                }
            }
        }
        defer { observer.cancel() }

        let sentinel = " active oversized capture sentinel"
        let text = String(repeating: "x", count: 8_650_772 - sentinel.utf8.count) + sentinel
        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString(text, forType: .string))
        await fulfillment(of: [oversizedPublished], timeout: 15)

        let page = try await backend.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.mutationSeq, gapSequence)
        let captured = try XCTUnwrap(page.items.first { $0.plainText.hasSuffix(sentinel) })
        XCTAssertEqual(captured.plainText.utf8.count, 8_650_772)
        let search = try await backend.search(query: SearchRequest(
            query: "active oversized capture sentinel", mode: .exact, limit: 10
        ))
        XCTAssertEqual(search.hits.map(\.item.id), [captured.id])
        XCTAssertEqual(search.mutationSeq, page.mutationSeq)

        try await backend.clearAll()
        await fulfillment(of: [clearPublished], timeout: 3)
        guard let clearCommit,
              case .itemsCleared(let deletedIDs) = clearCommit.change else {
            return XCTFail("The live publisher must resume with the exact clear commit")
        }
        XCTAssertEqual(Set(deletedIDs), [fixture.itemID, captured.id])
        XCTAssertEqual(clearCommit.totalCount, 0)
        XCTAssertEqual(clearCommit.mutationSeq, page.mutationSeq + 1)
        let emptyPage = try await backend.fetchHistoryPage(limit: 10, after: nil)
        XCTAssertTrue(emptyPage.items.isEmpty)
        XCTAssertEqual(emptyPage.total, 0)
        let emptySearch = try await backend.search(query: SearchRequest(
            query: "active oversized capture sentinel", mode: .exact, limit: 10
        ))
        XCTAssertTrue(emptySearch.hits.isEmpty)
        XCTAssertEqual(emptySearch.mutationSeq, emptyPage.mutationSeq)
    }

    func testStopCancelsAndJoinsInlineIngestCompression() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-ingest-compression-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("pngquant-test-double")
        let script = """
        #!/bin/bash
        trap 'printf cancelled > "$0.cancelled"; exit 0' TERM
        printf '%s' "$$" > "$0.pid.tmp"
        /bin/mv "$0.pid.tmp" "$0.pid"
        SECONDS=0
        while (( SECONDS < 6 )); do :; done
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let settingsStore = SettingsStore(suiteName: directory.appendingPathComponent("settings").path)
        var settings = SettingsDTO.default
        settings.pngquantBinaryPath = binary.path
        settings.pngquantCopyImageEnabled = true
        settings.showImageThumbnails = false
        await settingsStore.save(settings)
        let pasteboard = NSPasteboard.withUniqueName()
        let backend = ClipboardBackend(
            databasePath: directory.appendingPathComponent("clipboard.db").path,
            settingsStore: settingsStore, monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.01
        )
        let privatePasteboardName = pasteboard.name.rawValue
        addTeardownBlock {
            await backend.stop()
            await MainActor.run {
                NSPasteboard(name: NSPasteboard.Name(privatePasteboardName)).releaseGlobally()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try await backend.start()
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scopy/Assets.xcassets/AppIcon.appiconset/icon_16x16.png")
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertLessThan(data.count, ScopyThresholds.ingestSpoolBytes)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(data, forType: .png))
        let pidURL = URL(fileURLWithPath: binary.path + ".pid")
        await waitForConditionAsync(timeout: 3, pollInterval: 0.01) {
            FileManager.default.fileExists(atPath: pidURL.path)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        await backend.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path + ".cancelled"),
                      "Stop must cancel the compressor instead of waiting for its normal exit")
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "Stop must join the actual compressor process")
        XCTAssertEqual(errno, ESRCH)
    }

    private func makeHistoryFixture(monitorPollingInterval: TimeInterval = 60) async throws -> (
        backend: ClipboardBackend, directory: URL, itemID: UUID, initialMutationSeq: Int64,
        pasteboard: NSPasteboard
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-commit-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let seed = StorageService(databasePath: databasePath)
        try await seed.open()
        let item = try await seed.upsertItem(ClipboardMonitor.ClipboardContent(
            type: .text, plainText: "publication fixture", payload: .none,
            appBundleID: nil, contentHash: "publication-fixture", sizeBytes: 19
        ))
        await seed.close()
        let settings = SettingsStore(suiteName: directory.appendingPathComponent("settings").path)
        await settings.save(.default)
        let pasteboard = NSPasteboard.withUniqueName()
        let backend = ClipboardBackend(
            databasePath: databasePath, settingsStore: settings,
            monitorPasteboardName: pasteboard.name.rawValue, monitorPollingInterval: monitorPollingInterval
        )
        try await backend.start()
        let privatePasteboardName = pasteboard.name.rawValue
        addTeardownBlock {
            await backend.stop()
            await MainActor.run {
                NSPasteboard(name: NSPasteboard.Name(privatePasteboardName)).releaseGlobally()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let page = try await backend.fetchHistoryPage(limit: 10, after: nil)
        return (backend, directory, item.id, page.mutationSeq, pasteboard)
    }

}
