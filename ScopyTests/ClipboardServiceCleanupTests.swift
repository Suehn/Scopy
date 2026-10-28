import AppKit
import Darwin
import XCTest

@testable import ScopyKit

private actor CleanupCommitGate {
    private var didPause = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !didPause else { return }
        didPause = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class ClipboardServiceCleanupTests: XCTestCase {
    func testStopDrainsCommittedCleanupAndKeepsItsWriterLockAfterCallerCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-cleanup-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let seedStorage = StorageService(databasePath: databasePath)
        try await seedStorage.open()
        let oldest = try await seedStorage.upsertItem(makeTextContent("oldest"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await seedStorage.upsertItem(makeTextContent("newest"))
        await seedStorage.close()

        let settingsStore = SettingsStore(suiteName: directory.appendingPathComponent("settings").path)
        await settingsStore.save(.default)

        let service = ClipboardBackend(
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: NSPasteboard.withUniqueName().name.rawValue,
            monitorPollingInterval: 60
        )
        try await service.start()

        let gate = CleanupCommitGate()
        let publicationGate = CleanupCommitGate()
        await service.setHistoryPublicationInterlockForTesting { _ in
            await publicationGate.pause()
        }
        await service.setCleanupInterlockForTesting { point in
            guard case .afterCommitBeforeFileCleanup(let deletedItemIDs) = point,
                  deletedItemIDs.contains(oldest.id) else { return }
            await gate.pause()
        }

        let removalDelivered = expectation(description: "committed cleanup bulk event delivered")
        var deliveredIDs: [UUID] = []
        let eventTask = Task { @MainActor in
            for await event in service.eventStream {
                guard case .history(let committed) = event,
                      case .itemsRemoved(let itemIDs) = committed.change else { continue }
                deliveredIDs = itemIDs
                removalDelivered.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        var patch = SettingsPatch()
        patch.maxItems = 1
        let updateTask = Task {
            try await service.updateSettings(patch)
        }

        await gate.waitUntilPaused()
        await publicationGate.waitUntilPaused()
        updateTask.cancel()
        let stopTask = Task { await service.stop() }
        await waitForConditionAsync(timeout: 2, pollInterval: 0.01) {
            await service.isDrainingStorageRequestsForTesting
        }
        do {
            _ = try await service.fetchRecent(limit: 1, offset: 0)
            XCTFail("Shutdown must reject new storage requests while draining the admitted ones")
        } catch {
            if case ClipboardBackend.ClipboardBackendError.notStarted = error {
                // Expected: the admitted cleanup owns the store, but new callers cannot borrow it.
            } else {
                XCTFail("Unexpected shutdown admission error: \(error)")
            }
        }

        let lockPath = directory.appendingPathComponent(StorageRootLock.lockFileName).path
        do {
            let descriptor = try StorageRootLock.lockFile(atPath: lockPath)
            close(descriptor)
            XCTFail("Shutdown released its writer lock while committed cleanup was still paused")
        } catch {
            XCTAssertEqual(error as? StorageRootLock.HeldByAnotherProcess, .init(rootPath: directory.path))
        }

        await gate.release()
        await waitForConditionAsync(timeout: 2, pollInterval: 0.01) {
            await service.isDrainingHistoryForTesting
        }
        do {
            let descriptor = try StorageRootLock.lockFile(atPath: lockPath)
            close(descriptor)
            XCTFail("Shutdown released its writer lock before publishing the final committed sequence")
        } catch {
            XCTAssertEqual(error as? StorageRootLock.HeldByAnotherProcess, .init(rootPath: directory.path))
        }
        await publicationGate.release()
        await fulfillment(of: [removalDelivered], timeout: 2.0)
        _ = try? await updateTask.value
        await stopTask.value
        let reacquired = try StorageRootLock.lockFile(atPath: lockPath)
        close(reacquired)

        XCTAssertEqual(deliveredIDs, [oldest.id])
        let verifier = StorageService(databasePath: databasePath)
        try await verifier.open()
        let remainingCount = try await verifier.getItemCount()
        await verifier.close()
        XCTAssertEqual(remainingCount, 1)
    }

    private func makeTextContent(_ text: String) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            payload: .none,
            appBundleID: "com.scopy.tests",
            contentHash: "cleanup-\(text)-\(UUID().uuidString)",
            sizeBytes: text.utf8.count
        )
    }
}
