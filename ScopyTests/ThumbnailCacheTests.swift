import AppKit
import XCTest
@testable import ScopyUISupport

@MainActor
final class ThumbnailCacheTests: XCTestCase {
    func testCoalescedConsumersReceiveTheSameImageAndOneDecode() async throws {
        let gate = ThumbnailDecodeGate()
        let cache = ThumbnailCache.makeForTesting { path, _ in await gate.decode(path: path) }
        let first = Task { await cache.loadImage(path: "shared") }
        let second = Task { await cache.loadImage(path: "shared", priority: .userInitiated) }
        try await waitUntil { cache.snapshotForTesting().waiterCount == 2 }
        try await waitUntil { await gate.startedCount == 1 }

        await gate.complete(0, with: try image(width: 2))
        let one = await first.value
        let two = await second.value
        XCTAssertNotNil(one)
        XCTAssertTrue(one === two)
        XCTAssertTrue(one === cache.cachedImage(path: "shared"))
        XCTAssertEqual(cache.snapshotForTesting().activeCount, 0)
        XCTAssertEqual(cache.snapshotForTesting().waiterCount, 0)
        let decodedCount = await gate.startedCount
        XCTAssertEqual(decodedCount, 1)
    }

    func testCancelledConsumerDoesNotCancelAnotherAndWaiterLimitIsEnforced() async throws {
        let gate = ThumbnailDecodeGate()
        let cache = ThumbnailCache.makeForTesting(maxWaiters: 2) { path, _ in await gate.decode(path: path) }
        let first = Task { await cache.loadImage(path: "shared") }
        let second = Task { await cache.loadImage(path: "shared") }
        try await waitUntil { cache.snapshotForTesting().waiterCount == 2 }
        try await waitUntil { await gate.startedCount == 1 }

        let rejected = await cache.loadImage(path: "overflow")
        XCTAssertNil(rejected)
        XCTAssertEqual(cache.snapshotForTesting().pendingCount, 0)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(cache.snapshotForTesting().waiterCount, 1)
        XCTAssertEqual(cache.snapshotForTesting().activeCount, 1)

        await gate.complete(0, with: try image(width: 2))
        let surviving = await second.value
        XCTAssertNotNil(surviving)
        XCTAssertTrue(surviving === cache.cachedImage(path: "shared"))
    }

    func testInvalidationCannotRefillCacheOrJoinANewerLoadOfTheSamePath() async throws {
        for clearEverything in [false, true] {
            let gate = ThumbnailDecodeGate()
            let cache = ThumbnailCache.makeForTesting(limit: 1) { path, _ in await gate.decode(path: path) }
            let old = Task { await cache.loadImage(path: "replaced") }
            try await waitUntil { await gate.startedCount == 1 }

            if clearEverything { cache.clear() } else { cache.remove(path: "replaced") }
            let invalidated = await old.value
            XCTAssertNil(invalidated)
            XCTAssertNil(cache.cachedImage(path: "replaced"))
            XCTAssertEqual(cache.snapshotForTesting().activeCount, 1,
                           "A decode already inside ImageIO must retain its slot until it returns")

            let replacement = Task { await cache.loadImage(path: "replaced") }
            try await waitUntil { cache.snapshotForTesting().pendingCount == 1 }
            await gate.complete(0, with: try image(width: 1))
            try await waitUntil { await gate.startedCount == 2 }
            XCTAssertNil(cache.cachedImage(path: "replaced"), "The invalidated image must never be published")
            XCTAssertEqual(cache.snapshotForTesting().activeCount, 1)

            await gate.complete(1, with: try image(width: 2))
            let current = await replacement.value
            XCTAssertEqual(current?.size.width, 2)
            XCTAssertTrue(current === cache.cachedImage(path: "replaced"))
            XCTAssertEqual(cache.snapshotForTesting().activeCount, 0)
        }
    }

    func testRemovingOnePathPreservesOtherQueuedLoads() async throws {
        let gate = ThumbnailDecodeGate()
        let cache = ThumbnailCache.makeForTesting(limit: 1, maxPending: 2) { path, _ in await gate.decode(path: path) }
        let active = Task { await cache.loadImage(path: "active") }
        try await waitUntil { await gate.startedCount == 1 }
        let removed = Task { await cache.loadImage(path: "removed") }
        let kept = Task { await cache.loadImage(path: "kept") }
        try await waitUntil { cache.snapshotForTesting().pendingCount == 2 }
        let overflow = await cache.loadImage(path: "overflow")
        XCTAssertNil(overflow)

        cache.remove(path: "removed")
        let removedImage = await removed.value
        XCTAssertNil(removedImage)
        XCTAssertEqual(cache.snapshotForTesting().pendingPaths, ["kept"])
        await gate.complete(0, with: try image(width: 1))
        _ = await active.value
        try await waitUntil { await gate.startedCount == 2 }
        await gate.complete(1, with: try image(width: 2))
        let keptImage = await kept.value
        XCTAssertEqual(keptImage?.size.width, 2)
        let paths = await gate.startedPaths
        XCTAssertEqual(paths, ["active", "kept"])
    }

    private func image(width: Int) throws -> SendableThumbnailCGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return SendableThumbnailCGImage(image: try XCTUnwrap(context.makeImage()))
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for thumbnail work", file: file, line: line)
        throw NSError(domain: "ThumbnailCacheTests", code: 1)
    }
}

/// Deliberately ignores cancellation, like an ImageIO decode that has already entered native code.
private actor ThumbnailDecodeGate {
    private var completions: [Int: CheckedContinuation<SendableThumbnailCGImage?, Never>] = [:]
    private(set) var startedPaths: [String] = []
    var startedCount: Int { startedPaths.count }

    func decode(path: String) async -> SendableThumbnailCGImage? {
        let call = startedPaths.count
        startedPaths.append(path)
        return await withCheckedContinuation { completions[call] = $0 }
    }

    func complete(_ call: Int, with image: SendableThumbnailCGImage) {
        completions.removeValue(forKey: call)?.resume(returning: image)
    }
}
