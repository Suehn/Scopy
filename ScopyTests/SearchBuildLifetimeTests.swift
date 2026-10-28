import XCTest
@testable import ScopyKit

private actor ControlledSearchBuild {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run() async {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilRunning() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class SearchBuildLifetimeTests: XCTestCase {
    func testCloseJoinsBuildCancelledByEarlierInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-search-close-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("clipboard.db").path
        let repository = SQLiteClipboardRepository(dbPath: path)
        try await repository.open()
        let engine = SearchEngineImpl(dbPath: path, commitJournal: repository.commitJournal)
        try await engine.open()

        let retired = ControlledSearchBuild()
        let retiredCancelled = expectation(description: "The first build was cancelled")
        let retiredTask = Task.detached {
            await withTaskCancellationHandler {
                await retired.run()
            } onCancel: {
                retiredCancelled.fulfill()
            }
        }
        await retired.waitUntilRunning()
        await engine.debugInstallPendingShortQueryIndexBuild(retiredTask)
        await engine.invalidateCache()
        await fulfillment(of: [retiredCancelled], timeout: 2)

        let active = ControlledSearchBuild()
        let closeEntered = expectation(description: "Close cancelled the current build")
        let activeTask = Task.detached {
            await withTaskCancellationHandler {
                await active.run()
            } onCancel: {
                closeEntered.fulfill()
            }
        }
        await active.waitUntilRunning()
        await engine.debugInstallPendingShortQueryIndexBuild(activeTask)
        let returned = expectation(description: "Close returned before the retired worker finished")
        returned.isInverted = true
        let closeTask = Task {
            await engine.close()
            returned.fulfill()
        }
        await fulfillment(of: [closeEntered], timeout: 2)
        do {
            try await engine.open()
            XCTFail("Open must not enter a closing engine")
        } catch SearchEngineImpl.SearchError.databaseNotOpen {
        }
        let secondReturned = expectation(description: "A concurrent close must join the first close")
        secondReturned.isInverted = true
        let secondClose = Task {
            await engine.close()
            secondReturned.fulfill()
        }
        await active.release()
        await activeTask.value
        // The active worker ended, but the earlier invalidation still owns real unfinished work.
        await fulfillment(of: [returned, secondReturned], timeout: 0.05)
        await retired.release()
        await closeTask.value
        await secondClose.value
        try await engine.open()
        let reopened = try await engine.search(request: SearchRequest(query: "", mode: .exact))
        XCTAssertTrue(reopened.items.isEmpty)
        await engine.close()
        await repository.close()
    }
}
