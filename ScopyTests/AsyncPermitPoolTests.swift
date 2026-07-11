import XCTest

@testable import ScopyKit

private actor BoolBox {
    private var value = false

    func setTrue() {
        value = true
    }

    func get() -> Bool {
        value
    }
}

private actor PermitGrantGate {
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        didPause = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

final class AsyncPermitPoolTests: XCTestCase {
    func testReleaseUnblocksNextWaiter() async throws {
        let pool = AsyncPermitPool(limit: 1)
        let didAcquireSecond = BoolBox()

        let firstAcquire = await pool.acquire()
        XCTAssertTrue(firstAcquire)

        let waiter = Task {
            let granted = await pool.acquire()
            if granted {
                await didAcquireSecond.setTrue()
            }
            return granted
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let acquiredBeforeRelease = await didAcquireSecond.get()
        XCTAssertFalse(acquiredBeforeRelease)

        await pool.release()

        let waiterGranted = await waiter.value
        let acquiredAfterRelease = await didAcquireSecond.get()
        XCTAssertTrue(waiterGranted)
        XCTAssertTrue(acquiredAfterRelease)
        await pool.release()
    }

    func testCancelledWaiterDoesNotLeakPermit() async throws {
        let pool = AsyncPermitPool(limit: 1)

        let firstAcquire = await pool.acquire()
        XCTAssertTrue(firstAcquire)

        let waiter = Task {
            await pool.acquire()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()

        let waiterGranted = await waiter.value
        XCTAssertFalse(waiterGranted)

        await pool.release()

        let reacquired = await pool.acquire()
        XCTAssertTrue(reacquired)
        await pool.release()
    }

    func testBoundedPendingQueueRejectsExcessWaiterWithoutConsumingPermit() async throws {
        let pool = AsyncPermitPool(limit: 1, maxPending: 1)

        let firstGranted = await pool.acquire()
        XCTAssertTrue(firstGranted)
        let queued = Task { await pool.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let excessGranted = await pool.acquire()
        XCTAssertFalse(excessGranted)

        await pool.release()
        let queuedGranted = await queued.value
        XCTAssertTrue(queuedGranted)
        await pool.release()

        let reacquired = await pool.acquire()
        XCTAssertTrue(reacquired)
        await pool.release()
    }

    func testAlreadyCancelledTaskDoesNotConsumeImmediatePermit() async {
        let pool = AsyncPermitPool(limit: 1)
        let cancelled = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await pool.acquire()
        }
        cancelled.cancel()

        let cancelledGranted = await cancelled.value
        XCTAssertFalse(cancelledGranted)
        let acquired = await pool.acquire()
        XCTAssertTrue(acquired)
        await pool.release()
    }

    func testCancellationAfterQueuedGrantReturnsPermitToNextCaller() async {
        let grantGate = PermitGrantGate()
        let pool = AsyncPermitPool(
            limit: 1,
            afterQueuedGrant: { await grantGate.pause() }
        )
        let firstGranted = await pool.acquire()
        XCTAssertTrue(firstGranted)

        let waiter = Task { await pool.acquire() }
        while await pool.queuedWaiterCount() == 0 {
            await Task.yield()
        }

        await pool.release()
        await grantGate.waitUntilPaused()
        waiter.cancel()
        await grantGate.release()

        let cancelledGrant = await waiter.value
        XCTAssertFalse(cancelledGrant)
        let reacquired = await pool.acquire()
        XCTAssertTrue(reacquired)
        await pool.release()
    }

    func testCancelledNonOwnerDoesNotReleaseActiveCallersPermit() async {
        let pool = AsyncPermitPool(limit: 1)
        let ownerGranted = await pool.acquire()
        XCTAssertTrue(ownerGranted)

        let cancelledCaller = Task { await pool.acquire() }
        while await pool.queuedWaiterCount() == 0 {
            await Task.yield()
        }
        cancelledCaller.cancel()

        let cancelledGranted = await cancelledCaller.value
        XCTAssertFalse(cancelledGranted)
        let afterCancellation = await pool.snapshot()
        XCTAssertEqual(afterCancellation.activeCount, 1)
        XCTAssertEqual(afterCancellation.queuedCount, 0)

        let nextCaller = Task { await pool.acquire() }
        while await pool.queuedWaiterCount() == 0 {
            await Task.yield()
        }
        let whileOwnerActive = await pool.snapshot()
        XCTAssertEqual(whileOwnerActive.activeCount, 1)
        XCTAssertEqual(whileOwnerActive.queuedCount, 1)

        await pool.release()
        let nextGranted = await nextCaller.value
        XCTAssertTrue(nextGranted)
        await pool.release()
        let drained = await pool.snapshot()
        XCTAssertEqual(drained.activeCount, 0)
        XCTAssertEqual(drained.queuedCount, 0)
    }
}
