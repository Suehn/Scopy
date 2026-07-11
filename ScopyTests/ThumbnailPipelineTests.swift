import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScopyKit
@testable import ScopyUISupport

private actor AsyncExecutionGate<Key: Hashable & Sendable> {
    struct Snapshot: Sendable {
        let activeCount: Int
        let maxActiveCount: Int
        let started: [Key]
        let finished: [Key]
        let invocationCount: [Key: Int]
    }

    private var released: Set<Key> = []
    private var active: Set<Key> = []
    private var maxActiveCount = 0
    private var started: [Key] = []
    private var finished: [Key] = []
    private var invocationCount: [Key: Int] = [:]

    func run(_ key: Key) async {
        active.insert(key)
        maxActiveCount = max(maxActiveCount, active.count)
        started.append(key)
        invocationCount[key, default: 0] += 1

        while !released.contains(key), !Task.isCancelled {
            await Task.yield()
        }

        active.remove(key)
        finished.append(key)
    }

    func release(_ key: Key) {
        released.insert(key)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeCount: active.count,
            maxActiveCount: maxActiveCount,
            started: started,
            finished: finished,
            invocationCount: invocationCount
        )
    }
}

private actor CompletionRecorder<Value: Sendable> {
    private var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }

    func snapshot() -> [Value] {
        values
    }
}

@MainActor
final class ThumbnailPipelineTests: XCTestCase {
    func testMakeThumbnailPNGFromFilePathDownsamplesToMaxHeight() throws {
        let url = try writeTestPNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let maxHeight = 120
        guard let pngData = StorageService.makeThumbnailPNG(fromFileAtPath: url.path, maxHeight: maxHeight) else {
            XCTFail("Expected PNG thumbnail data")
            return
        }

        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            XCTFail("Expected CGImageSource from thumbnail PNG data")
            return
        }

        let type = CGImageSourceGetType(source) as String?
        XCTAssertEqual(type, UTType.png.identifier)

        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        XCTAssertNotNil(cgImage)
        if let cgImage {
            XCTAssertLessThanOrEqual(abs(cgImage.height - maxHeight), 1)
        }
    }

    func testThumbnailCacheRemoveEvictsCachedImage() async throws {
        let url = try writeTestPNG(width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: url) }

        let path = url.path
        ThumbnailCache.shared.clear()
        XCTAssertNil(ThumbnailCache.shared.cachedImage(path: path))

        let loaded = await ThumbnailCache.shared.loadImage(path: path, priority: .userInitiated)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(ThumbnailCache.shared.cachedImage(path: path))

        ThumbnailCache.shared.remove(path: path)
        XCTAssertNil(ThumbnailCache.shared.cachedImage(path: path))
    }

    func testBoundedWorkerQueueEnforcesActivePendingLimitsAndCoalesces() async throws {
        let gate = AsyncExecutionGate<Int>()
        let completions = CompletionRecorder<Int>()
        let queue = BoundedCoalescingWorkerQueue<Int, Int, Int>(
            workerLimit: 2,
            pendingLimit: 3,
            merge: { _, incoming in incoming },
            operation: { work, _ in
                await gate.run(work)
                return work
            },
            completion: { _, output in
                await completions.record(output)
            }
        )
        await queue.start()

        _ = await queue.submit(key: 1, work: 1, priority: .utility)
        _ = await queue.submit(key: 2, work: 2, priority: .utility)
        try await waitUntil {
            let snapshot = await queue.snapshot()
            return snapshot.activeCount == 2
        }

        _ = await queue.submit(key: 3, work: 3, priority: .utility)
        _ = await queue.submit(key: 4, work: 4, priority: .utility)
        _ = await queue.submit(key: 5, work: 5, priority: .utility)
        let duplicate = await queue.submit(key: 4, work: 4, priority: .utility)
        let overflow = await queue.submit(key: 6, work: 6, priority: .utility)

        if case .coalescedPending(let upgraded) = duplicate {
            XCTAssertFalse(upgraded)
        } else {
            XCTFail("Expected pending duplicate to coalesce")
        }
        if case .rejectedFull = overflow {
            // Expected.
        } else {
            XCTFail("Expected utility overflow to be rejected")
        }

        let bounded = await queue.snapshot()
        XCTAssertEqual(bounded.activeCount, 2)
        XCTAssertEqual(bounded.pendingCount, 3)
        XCTAssertLessThanOrEqual(bounded.maxActiveCount, 2)
        XCTAssertLessThanOrEqual(bounded.maxPendingCount, 3)

        for key in 1...5 {
            await gate.release(key)
        }
        try await waitUntil {
            let snapshot = await queue.snapshot()
            return snapshot.activeCount == 0 && snapshot.pendingCount == 0
        }
        let completed = await completions.snapshot()
        XCTAssertEqual(Set(completed), Set(1...5))
        XCTAssertEqual(completed.count, 5)

        await queue.stop()
        let stopped = await queue.snapshot()
        XCTAssertFalse(stopped.isRunning)
        XCTAssertEqual(stopped.workerCount, 0)
        XCTAssertEqual(stopped.waitingWorkerCount, 0)
    }

    func testBoundedWorkerQueueUpgradesAndVisibleRequestReplacesOldestUtility() async throws {
        let gate = AsyncExecutionGate<Int>()
        let queue = BoundedCoalescingWorkerQueue<Int, Int, Int>(
            workerLimit: 1,
            pendingLimit: 2,
            merge: { _, incoming in incoming },
            operation: { work, _ in
                await gate.run(work)
                return work
            },
            completion: { _, _ in }
        )
        await queue.start()

        _ = await queue.submit(key: 0, work: 0, priority: .utility)
        try await waitUntil { await queue.snapshot().activeCount == 1 }
        _ = await queue.submit(key: 1, work: 1, priority: .utility)
        _ = await queue.submit(key: 2, work: 2, priority: .utility)

        let upgrade = await queue.submit(key: 2, work: 2, priority: .userInitiated)
        if case .coalescedPending(let upgraded) = upgrade {
            XCTAssertTrue(upgraded)
        } else {
            XCTFail("Expected priority upgrade to coalesce")
        }

        let replacement = await queue.submit(key: 3, work: 3, priority: .userInitiated)
        if case .replacedOldestUtility(let replacedKey) = replacement {
            XCTAssertEqual(replacedKey, 1)
        } else {
            XCTFail("Expected visible work to replace the oldest utility request")
        }

        let pending = await queue.snapshot()
        XCTAssertEqual(pending.pendingKeys, [2, 3])
        XCTAssertEqual(pending.pendingPriorities, [.userInitiated, .userInitiated])

        await gate.release(0)
        await gate.release(2)
        await gate.release(3)
        try await waitUntil {
            let snapshot = await queue.snapshot()
            return snapshot.pendingCount == 0 && snapshot.activeCount == 0
        }
        let execution = await gate.snapshot().started
        XCTAssertEqual(execution, [0, 2, 3])
        XCTAssertFalse(execution.contains(1))
        await queue.stop()
    }

    func testBoundedWorkerQueueStopCancelsWorkersAndClearsOwnership() async throws {
        let gate = AsyncExecutionGate<Int>()
        let queue = BoundedCoalescingWorkerQueue<Int, Int, Int>(
            workerLimit: 1,
            pendingLimit: 2,
            merge: { _, incoming in incoming },
            operation: { work, _ in
                await gate.run(work)
                return work
            },
            completion: { _, _ in }
        )
        await queue.start()
        _ = await queue.submit(key: 1, work: 1, priority: .utility)
        _ = await queue.submit(key: 2, work: 2, priority: .utility)
        try await waitUntil { await queue.snapshot().activeCount == 1 }

        await queue.stop()

        let snapshot = await queue.snapshot()
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.pendingCount, 0)
        XCTAssertEqual(snapshot.workerCount, 0)
        XCTAssertEqual(snapshot.waitingWorkerCount, 0)
        let gateSnapshot = await gate.snapshot()
        XCTAssertEqual(gateSnapshot.activeCount, 0)
    }

    func testRetryTimestampRegistryIsBoundedAndPrunesExpiredEntries() {
        var registry = BoundedRetryTimestamps<Int>(capacity: 3)
        let now = Date()
        for key in 0..<6 {
            registry.record(key, at: now.addingTimeInterval(TimeInterval(key)))
        }
        XCTAssertEqual(registry.count, 3)
        XCTAssertFalse(registry.containsRecent(0, now: now.addingTimeInterval(6), interval: 60))
        XCTAssertTrue(registry.containsRecent(5, now: now.addingTimeInterval(6), interval: 60))
        _ = registry.containsRecent(5, now: now.addingTimeInterval(120), interval: 1)
        XCTAssertEqual(registry.count, 0)
    }

    func testClipboardEventQueueRejectsOlderPublicationThatArrivesAfterNewerOne() async {
        let queue = ClipboardEventQueue(capacity: 4)
        let itemID = UUID()
        let oldToken = await queue.reservePublication(itemID: itemID)
        let newToken = await queue.reservePublication(itemID: itemID)
        let oldItem = ClipboardItemDTO(
            id: itemID,
            type: .text,
            contentHash: "old",
            plainText: "old",
            note: nil,
            appBundleID: nil,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: 3,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil
        )
        let newItem = ClipboardItemDTO(
            id: itemID,
            type: .text,
            contentHash: "new",
            plainText: "new",
            note: nil,
            appBundleID: nil,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: 3,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil
        )

        let acceptedNew = await queue.enqueue(
            .itemContentUpdated(newItem),
            publication: newToken
        )
        let acceptedOld = await queue.enqueue(
            .itemContentUpdated(oldItem),
            publication: oldToken
        )
        XCTAssertTrue(acceptedNew)
        XCTAssertFalse(acceptedOld)
        guard case .itemContentUpdated(let delivered)? = await queue.dequeue() else {
            return XCTFail("Expected the newer item event")
        }
        XCTAssertEqual(delivered.contentHash, "new")
        await queue.finish()
    }

    func testThumbnailDecodeCoordinatorBoundsUniqueWorkAndSharesDuplicatePath() async throws {
        let gate = AsyncExecutionGate<String>()
        let coordinator = ThumbnailDecodeCoordinator(
            limit: 1,
            maxPending: 2,
            maxWaiters: 4,
            decodeOperation: { path, _ in
                await gate.run(path)
                return nil
            }
        )

        let active = Task { await coordinator.load(path: "active", priority: .utility) }
        try await waitUntil { await coordinator.snapshot().activeUniqueCount == 1 }
        let utility = Task { await coordinator.load(path: "utility", priority: .utility) }
        try await waitUntil { await coordinator.snapshot().pendingPaths == ["utility"] }
        let upgraded = Task { await coordinator.load(path: "upgraded", priority: .utility) }
        try await waitUntil { await coordinator.snapshot().pendingUniqueCount == 2 }
        let upgradedDuplicate = Task { await coordinator.load(path: "upgraded", priority: .userInitiated) }
        try await waitUntil { await coordinator.snapshot().totalWaiterCount == 4 }
        let visibleReplacement = Task { await coordinator.load(path: "visible", priority: .userInitiated) }

        try await waitUntil {
            let snapshot = await coordinator.snapshot()
            return snapshot.pendingPaths == ["upgraded", "visible"]
        }
        let bounded = await coordinator.snapshot()
        XCTAssertEqual(bounded.activeUniqueCount, 1)
        XCTAssertEqual(bounded.pendingUniqueCount, 2)
        XCTAssertLessThanOrEqual(bounded.totalWaiterCount, 4)
        XCTAssertEqual(bounded.pendingUserInitiated, [true, true])
        XCTAssertLessThanOrEqual(bounded.maxActiveUniqueCount, 1)
        XCTAssertLessThanOrEqual(bounded.maxPendingUniqueCount, 2)
        XCTAssertLessThanOrEqual(bounded.maxTotalWaiterCount, 4)

        await gate.release("active")
        await gate.release("upgraded")
        await gate.release("visible")
        _ = await active.value
        _ = await utility.value
        _ = await upgraded.value
        _ = await upgradedDuplicate.value
        _ = await visibleReplacement.value
        try await waitUntil {
            let snapshot = await coordinator.snapshot()
            return snapshot.activeUniqueCount == 0 && snapshot.pendingUniqueCount == 0
        }

        let invocations = await gate.snapshot().invocationCount
        XCTAssertEqual(invocations["upgraded"], 1, "Duplicate paths must share one decode")
        XCTAssertNil(invocations["utility"], "Visible replacement must drop the oldest utility decode")
        await coordinator.stop()
    }

    func testThumbnailDecodeCancellationDoesNotLeakWaitersOrActiveOwnership() async throws {
        let gate = AsyncExecutionGate<String>()
        let coordinator = ThumbnailDecodeCoordinator(
            limit: 1,
            maxPending: 2,
            maxWaiters: 4,
            decodeOperation: { path, _ in
                await gate.run(path)
                return nil
            }
        )

        let active = Task { await coordinator.load(path: "active", priority: .utility) }
        try await waitUntil { await coordinator.snapshot().activeUniqueCount == 1 }
        let pending = Task { await coordinator.load(path: "pending", priority: .utility) }
        try await waitUntil { await coordinator.snapshot().pendingUniqueCount == 1 }

        pending.cancel()
        active.cancel()
        _ = await pending.value
        _ = await active.value
        try await waitUntil {
            let snapshot = await coordinator.snapshot()
            return snapshot.totalWaiterCount == 0 && snapshot.pendingUniqueCount == 0
        }
        await gate.release("active")
        try await waitUntil { await coordinator.snapshot().activeUniqueCount == 0 }
        await coordinator.stop()
        let stopped = await coordinator.snapshot()
        XCTAssertEqual(stopped.workerCount, 0)
        XCTAssertEqual(stopped.waitingWorkerCount, 0)
        XCTAssertEqual(stopped.totalWaiterCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for async condition", file: file, line: line)
        throw NSError(domain: "ThumbnailPipelineTests", code: 99)
    }

    private func writeTestPNG(width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 1)
        }

        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 2)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-test-\(UUID().uuidString).png")

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 3)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ThumbnailPipelineTests", code: 4)
        }

        return url
    }
}
