import AppKit
import XCTest
import ScopyKit

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
