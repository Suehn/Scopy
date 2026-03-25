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
}
