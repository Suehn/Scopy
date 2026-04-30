import AppKit
import XCTest
import ScopyKit
@testable import ScopyUISupport

@MainActor
final class ScrollPerformanceTests: XCTestCase {

    private final class StubClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}
        func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] { [] }
        func search(query: SearchRequest) async throws -> SearchResultPage {
            SearchResultPage(items: [], total: 0, hasMore: false)
        }
        func pin(itemID: UUID) async throws {}
        func unpin(itemID: UUID) async throws {}
        func delete(itemID: UUID) async throws {}
        func clearAll() async throws {}
        func copyToClipboard(itemID: UUID) async throws {}
        func updateSettings(_ settings: SettingsDTO) async throws {}
        func getSettings() async throws -> SettingsDTO { .default }
        func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) { (0, 0) }
        func getDetailedStorageStats() async throws -> StorageStatsDTO {
            StorageStatsDTO(
                itemCount: 0,
                databaseSizeBytes: 0,
                externalStorageSizeBytes: 0,
                thumbnailSizeBytes: 0,
                totalSizeBytes: 0,
                databasePath: ""
            )
        }
        func getImageData(itemID: UUID) async throws -> Data? { nil }
        func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
            ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        func syncExternalImageSizeBytesFromDisk() async throws -> Int { 0 }
        func getRecentApps(limit: Int) async throws -> [String] { [] }
    }

    func testScrollStatePerformance() throws {
        let service = StubClipboardService()
        let settings = SettingsViewModel(service: service)
        let viewModel = HistoryViewModel(service: service, settingsViewModel: settings)

        let samples = try PerformanceHelpers.collectTimeSamples(
            iterations: 1000,
            warmupIterations: 20
        ) {
            viewModel.scrollDidStart()
            viewModel.scrollDidEnd()
        }

        let stats = PerformanceHelpers.calculateStats(samples)
        print(stats.report(title: "Scroll State Update Performance"))

        XCTAssertLessThan(
            stats.p95,
            2.0,
            "Scroll state updates should stay under 2ms at P95"
        )
    }

    func testScrollLiveNotificationCoalescing() {
        let (observer, scrollView) = makeObserver()
        var startCount = 0
        var endCount = 0

        observer.onScrollStart = { startCount += 1 }
        observer.onScrollEnd = { endCount += 1 }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )

        XCTAssertEqual(startCount, 1)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        XCTAssertEqual(endCount, 1)
    }

    func testScrollEndEmitsOnDetach() {
        let (observer, scrollView) = makeObserver()
        var endCount = 0
        observer.onScrollEnd = { endCount += 1 }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )

        observer.removeFromSuperview()

        XCTAssertEqual(endCount, 1)
    }

    func testScrollEndWithoutStartDoesNotFire() {
        let (observer, scrollView) = makeObserver()
        var endCount = 0
        observer.onScrollEnd = { endCount += 1 }

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        XCTAssertEqual(endCount, 0)
    }

    func testScrollObserverReattachesToNewScrollView() {
        let observer = ListLiveScrollObserverView.ObserverView(frame: .zero)
        let scrollViewA = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let scrollViewB = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))

        var startCount = 0
        var endCount = 0
        observer.onScrollStart = { startCount += 1 }
        observer.onScrollEnd = { endCount += 1 }

        scrollViewA.contentView.addSubview(observer)
        observer.attachIfNeeded()

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollViewA
        )

        XCTAssertEqual(startCount, 1)

        observer.removeFromSuperview()

        XCTAssertEqual(endCount, 1)

        scrollViewB.contentView.addSubview(observer)
        observer.attachIfNeeded()

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollViewA
        )

        XCTAssertEqual(startCount, 1)

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollViewB
        )

        XCTAssertEqual(startCount, 2)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollViewB
        )

        XCTAssertEqual(endCount, 2)
    }

    func testDisplayTextPrewarmImprovesMetadataAccessTime() async {
        let items = makeTextItems(count: 400, textLength: 4096)

        ClipboardItemDisplayText.shared.clearCaches()
        let cold = PerformanceHelpers.measureTime {
            for item in items {
                _ = ClipboardItemDisplayText.shared.metadata(for: item)
            }
        }

        ClipboardItemDisplayText.shared.clearCaches()
        let prewarmTask = ClipboardItemDisplayText.shared.prewarm(items: items)
        await prewarmTask?.value

        let cached = PerformanceHelpers.measureTime {
            for item in items {
                _ = ClipboardItemDisplayText.shared.metadata(for: item)
            }
        }

        print(
            "DisplayText metadata access: cold \(PerformanceHelpers.formatTime(cold.timeMs)), " +
            "cached \(PerformanceHelpers.formatTime(cached.timeMs))"
        )

        XCTAssertLessThan(
            cached.timeMs,
            cold.timeMs,
            "Cached metadata access should be faster than cold path"
        )
    }

    func testLongFrameAttributionUsesOverlappingMetricWindows() throws {
        let base = Date().timeIntervalSinceReferenceDate
        let frames = [
            ScrollPerformanceProfile.FrameSample(
                index: 0,
                start: base,
                end: base + 0.016,
                intervalMs: 16,
                offsetDelta: nil,
                scrollSpeed: nil,
                isScrolling: false
            ),
            ScrollPerformanceProfile.FrameSample(
                index: 1,
                start: base + 0.016,
                end: base + 0.066,
                intervalMs: 50,
                offsetDelta: 100,
                scrollSpeed: 2_000,
                isScrolling: true
            ),
            ScrollPerformanceProfile.FrameSample(
                index: 2,
                start: base + 0.066,
                end: base + 0.146,
                intervalMs: 80,
                offsetDelta: nil,
                scrollSpeed: nil,
                isScrolling: false
            )
        ]
        let events = [
            ScrollPerformanceProfile.MetricEvent(
                name: "row.display_model_ms",
                start: base + 0.020,
                end: base + 0.040,
                durationMs: 20
            ),
            ScrollPerformanceProfile.MetricEvent(
                name: "text.markdown_detect_ms",
                start: base + 0.025,
                end: base + 0.035,
                durationMs: 10
            ),
            ScrollPerformanceProfile.MetricEvent(
                name: "image.thumbnail_imageio_decode_ms",
                start: base + 0.070,
                end: base + 0.080,
                durationMs: 10
            ),
            ScrollPerformanceProfile.MetricEvent(
                name: "idle.metric_ms",
                start: base + 0.090,
                end: base + 0.130,
                durationMs: 40
            )
        ]

        let attribution = ScrollPerformanceProfile.buildLongFrameAttribution(
            frameSamples: frames,
            metricEvents: events,
            expectedFrameMs: 16.667,
            dropThresholdMultiplier: 1.5,
            maxFrameDetails: 4,
            timelineStart: base
        )

        XCTAssertEqual(attribution["long_frame_count"] as? Int, 1)
        XCTAssertEqual(attribution["total_frame_ms"] as? Double ?? 0, 50, accuracy: 0.1)
        XCTAssertEqual(attribution["attributed_union_ms"] as? Double ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(attribution["unattributed_ms"] as? Double ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(attribution["attribution_coverage_ratio"] as? Double ?? 0, 0.4, accuracy: 0.01)

        let topMetrics = try XCTUnwrap(attribution["top_metrics"] as? [[String: Any]])
        let rowMetric = try XCTUnwrap(topMetrics.first { $0["name"] as? String == "row.display_model_ms" })
        let markdownMetric = try XCTUnwrap(topMetrics.first { $0["name"] as? String == "text.markdown_detect_ms" })
        XCTAssertNil(topMetrics.first { $0["name"] as? String == "idle.metric_ms" })
        XCTAssertEqual(rowMetric["count"] as? Int, 1)
        XCTAssertEqual(rowMetric["overlap_ms"] as? Double ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(markdownMetric["overlap_ms"] as? Double ?? 0, 10, accuracy: 0.1)

        let detailFrames = try XCTUnwrap(attribution["frames"] as? [[String: Any]])
        let detailFrame = try XCTUnwrap(detailFrames.first)
        XCTAssertEqual(detailFrame["index"] as? Int, 1)
        XCTAssertEqual(detailFrame["event_count"] as? Int, 2)
        XCTAssertEqual(detailFrame["event_overlap_ms"] as? Double ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(detailFrame["event_union_overlap_ms"] as? Double ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(detailFrame["unattributed_ms"] as? Double ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(detailFrame["start_ms"] as? Double ?? 0, 16, accuracy: 0.1)
        XCTAssertEqual(detailFrame["end_ms"] as? Double ?? 0, 66, accuracy: 0.1)
    }

    private func makeObserver() -> (ListLiveScrollObserverView.ObserverView, NSScrollView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let observer = ListLiveScrollObserverView.ObserverView(frame: .zero)
        scrollView.contentView.addSubview(observer)
        observer.attachIfNeeded()
        return (observer, scrollView)
    }

    private func makeTextItems(count: Int, textLength: Int) -> [ClipboardItemDTO] {
        let plainText = makeTextPayload(length: textLength)
        let now = Date()
        var items: [ClipboardItemDTO] = []
        items.reserveCapacity(count)

        for _ in 0..<count {
            items.append(
                ClipboardItemDTO(
                    id: UUID(),
                    type: .text,
                    contentHash: UUID().uuidString,
                    plainText: plainText,
                    appBundleID: nil,
                    createdAt: now,
                    lastUsedAt: now,
                    isPinned: false,
                    sizeBytes: plainText.utf8.count,
                    thumbnailPath: nil,
                    storageRef: nil
                )
            )
        }

        return items
    }

    private func makeTextPayload(length: Int) -> String {
        let seed = "word word word\n"
        let repeats = max(1, length / seed.count + 1)
        let text = String(repeating: seed, count: repeats)
        return String(text.prefix(length))
    }
}
