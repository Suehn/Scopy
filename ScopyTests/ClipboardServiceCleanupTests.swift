import AppKit
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
    func testCancelledCallerStillPublishesCleanupCommittedBeforeCancellation() async throws {
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

        let suiteName = "scopy-cleanup-cancellation-settings-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(suiteName: suiteName)
        await settingsStore.save(.default)

        let service = ClipboardService(
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: NSPasteboard.withUniqueName().name.rawValue,
            monitorPollingInterval: 60
        )
        try await service.start()

        let gate = CleanupCommitGate()
        await service.setCleanupInterlockForTesting { point in
            guard case .afterCommitBeforeFileCleanup(let deletedItemIDs) = point,
                  deletedItemIDs.contains(oldest.id) else { return }
            await gate.pause()
        }

        let removalDelivered = expectation(description: "committed cleanup bulk event delivered")
        var deliveredIDs: [UUID] = []
        let eventTask = Task { @MainActor in
            for await event in service.eventStream {
                guard case .itemsRemoved(let itemIDs) = event else { continue }
                deliveredIDs = itemIDs
                removalDelivered.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        var reducedSettings = await service.getSettings()
        reducedSettings.maxItems = 1
        let updateTask = Task {
            try await service.updateSettings(reducedSettings)
        }

        await gate.waitUntilPaused()
        updateTask.cancel()
        await gate.release()
        await fulfillment(of: [removalDelivered], timeout: 2.0)
        _ = try? await updateTask.value
        await service.stop()

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
