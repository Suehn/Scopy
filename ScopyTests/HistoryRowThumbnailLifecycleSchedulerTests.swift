import AppKit
import ScopyUISupport
import XCTest

@testable import Scopy

@MainActor
final class HistoryRowThumbnailLifecycleSchedulerTests: XCTestCase {
    func testProductionCachedImageReadsSharedThumbnailCache() {
        let path = "/tmp/scopy-scheduler-production-cache-\(UUID().uuidString).png"
        let image = Self.makeImage()
        ThumbnailCache.shared.clear()
        defer { ThumbnailCache.shared.clear() }

        XCTAssertNil(HistoryRowThumbnailLifecycleScheduler.productionCachedImage(for: path))
        ThumbnailCache.shared.store(image, forPath: path)

        XCTAssertTrue(HistoryRowThumbnailLifecycleScheduler.productionCachedImage(for: path) === image)
    }

    func testCacheHitReturnsImmediatelyWithoutLoadOrSleep() async {
        let image = Self.makeImage()
        var loadCalls: [(String, TaskPriority)] = []
        var sleepCalls: [UInt64] = []

        let scheduler = makeScheduler(
            cachedImage: { path in path == "/tmp/cache.png" ? image : nil },
            loadImage: { path, priority in
                loadCalls.append((path, priority))
                return Self.makeImage()
            },
            isScrolling: { true },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/cache.png")

        XCTAssertEqual(result?.path, "/tmp/cache.png")
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.source, .cacheHit)
        XCTAssertTrue(loadCalls.isEmpty)
        XCTAssertTrue(sleepCalls.isEmpty)
    }

    func testCacheMissWhenNotScrollingUsesUserInitiatedAndCommitsLoaded() async {
        let image = Self.makeImage()
        var loadCalls: [(String, TaskPriority)] = []
        var sleepCalls: [UInt64] = []

        let scheduler = makeScheduler(
            loadImage: { path, priority in
                loadCalls.append((path, priority))
                return image
            },
            isScrolling: { false },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/load.png")

        XCTAssertEqual(loadCalls.map(\.0), ["/tmp/load.png"])
        XCTAssertEqual(loadCalls.map(\.1), [.userInitiated])
        XCTAssertEqual(result?.path, "/tmp/load.png")
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.source, .loaded)
        XCTAssertTrue(sleepCalls.isEmpty)
    }

    func testCacheMissWhileScrollingUsesUtilityAndSleepsUntilScrollingStops() async {
        let image = Self.makeImage()
        var loadCalls: [(String, TaskPriority)] = []
        var sleepCalls: [UInt64] = []
        var isScrollingChecks = 0

        let scheduler = makeScheduler(
            loadImage: { path, priority in
                loadCalls.append((path, priority))
                return image
            },
            isScrolling: {
                isScrollingChecks += 1
                return isScrollingChecks <= 3
            },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/scrolling.png")

        XCTAssertEqual(loadCalls.map(\.1), [.utility])
        XCTAssertEqual(sleepCalls, [80_000_000, 80_000_000])
        XCTAssertEqual(result?.path, "/tmp/scrolling.png")
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.source, .loaded)
    }

    func testBoundedWaitSleepsAtMostTwentyTimesWhenScrollingNeverStops() async {
        let image = Self.makeImage()
        var sleepCalls: [UInt64] = []

        let scheduler = makeScheduler(
            loadImage: { _, _ in image },
            isScrolling: { true },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/never-stops.png")

        XCTAssertEqual(sleepCalls.count, 20)
        XCTAssertTrue(sleepCalls.allSatisfy { $0 == 80_000_000 })
        XCTAssertEqual(result?.path, "/tmp/never-stops.png")
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.source, .loaded)
    }

    func testCancellationBeforeLoadReturnsNil() async {
        var loadCalls: [(String, TaskPriority)] = []
        var sleepCalls: [UInt64] = []

        let scheduler = makeScheduler(
            loadImage: { path, priority in
                loadCalls.append((path, priority))
                return Self.makeImage()
            },
            isScrolling: { false },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) },
            isCancelled: { true }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/cancel-before.png")

        XCTAssertNil(result)
        XCTAssertTrue(loadCalls.isEmpty)
        XCTAssertTrue(sleepCalls.isEmpty)
    }

    func testCancellationAfterLoadReturnsNil() async {
        let image = Self.makeImage()
        var cancellationChecks = 0
        var sleepCalls: [UInt64] = []

        let scheduler = makeScheduler(
            loadImage: { _, _ in image },
            isScrolling: { false },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) },
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 2
            }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/cancel-after-load.png")

        XCTAssertNil(result)
        XCTAssertTrue(sleepCalls.isEmpty)
    }

    func testCancellationDuringWaitReturnsNil() async {
        let image = Self.makeImage()
        var sleepCalls: [UInt64] = []
        var cancellationChecks = 0

        let scheduler = makeScheduler(
            loadImage: { _, _ in image },
            isScrolling: { true },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) },
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 3
            }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/cancel-during-wait.png")

        XCTAssertNil(result)
        XCTAssertEqual(sleepCalls, [80_000_000])
    }

    func testNilLoadReturnsNil() async {
        var sleepCalls: [UInt64] = []

        let scheduler = makeScheduler(
            loadImage: { _, _ in nil },
            isScrolling: { false },
            sleep: { nanoseconds in sleepCalls.append(nanoseconds) }
        )

        let result = await scheduler.loadCommitResult(for: "/tmp/missing.png")

        XCTAssertNil(result)
        XCTAssertTrue(sleepCalls.isEmpty)
    }

    func testPathTaggingPreservesRequestedPath() async {
        let image = Self.makeImage()
        let scheduler = makeScheduler(loadImage: { _, _ in image })

        let result = await scheduler.loadCommitResult(for: "/tmp/requested-path.png")

        XCTAssertEqual(result?.path, "/tmp/requested-path.png")
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.source, .loaded)
    }

    private func makeScheduler(
        cachedImage: @escaping (String) -> NSImage? = { _ in nil },
        loadImage: @escaping (String, TaskPriority) async -> NSImage? = { _, _ in nil },
        isScrolling: @escaping () -> Bool = { false },
        sleep: @escaping (UInt64) async -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) -> HistoryRowThumbnailLifecycleScheduler {
        HistoryRowThumbnailLifecycleScheduler(
            dependencies: HistoryRowThumbnailLifecycleScheduler.Dependencies(
                cachedImage: cachedImage,
                loadImage: loadImage,
                isScrolling: isScrolling,
                sleep: sleep,
                isCancelled: isCancelled
            )
        )
    }

    private static func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8))
    }
}
