import Foundation
import AppKit
import ScopyKit
import SwiftUI
import XCTest

@testable import Scopy

@MainActor
final class HistoryRelativeTimeClockTests: XCTestCase {
    @MainActor
    private final class ManualScheduler {
        private final class Entry {
            let deadline: TimeInterval
            let action: HistoryRelativeTimeClock.TickAction
            var cancelled = false

            init(deadline: TimeInterval, action: @escaping HistoryRelativeTimeClock.TickAction) {
                self.deadline = deadline
                self.action = action
            }
        }

        var now: Date
        private var entries: [Entry] = []

        init(timestamp: TimeInterval) {
            now = Date(timeIntervalSince1970: timestamp)
        }

        func schedule(
            delay: TimeInterval,
            action: @escaping HistoryRelativeTimeClock.TickAction
        ) -> HistoryRelativeTimeClock.Cancellation {
            let entry = Entry(deadline: now.timeIntervalSince1970 + delay, action: action)
            entries.append(entry)
            return HistoryRelativeTimeClock.Cancellation {
                entry.cancelled = true
            }
        }

        func advance(by interval: TimeInterval) {
            now = now.addingTimeInterval(interval)
            let due = entries.filter { $0.deadline <= now.timeIntervalSince1970 }
            entries.removeAll { $0.deadline <= now.timeIntervalSince1970 }
            for entry in due where !entry.cancelled {
                entry.action()
            }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            HistoryItemPresentationCache.shared.clearCaches()
        }
        super.tearDown()
    }

    func testClockPausesDuringScrollAndRefreshesAtAlignedBoundaryOnResume() {
        let scheduler = ManualScheduler(timestamp: 59)
        let clock = makeClock(scheduler)

        clock.start()
        XCTAssertFalse(clock.hasScheduledTick)
        clock.setWindowVisible(true)
        XCTAssertTrue(clock.hasScheduledTick)
        XCTAssertEqual(clock.bucket, 1)

        clock.scrollDidStart()
        XCTAssertFalse(clock.hasScheduledTick)
        scheduler.advance(by: 31)
        XCTAssertEqual(clock.bucket, 1)

        clock.scrollDidEnd()
        XCTAssertEqual(clock.bucket, 3)
        XCTAssertTrue(clock.hasScheduledTick)

        scheduler.advance(by: 30)
        XCTAssertEqual(clock.bucket, 4)
        XCTAssertTrue(clock.hasScheduledTick)
    }

    func testHiddenWindowCancelsPublicationAndVisibleWindowRefreshesImmediately() {
        let scheduler = ManualScheduler(timestamp: 10)
        let clock = makeClock(scheduler)
        clock.start()
        clock.setWindowVisible(true)
        XCTAssertTrue(clock.hasScheduledTick)

        clock.setWindowVisible(false)
        XCTAssertFalse(clock.hasScheduledTick)
        scheduler.advance(by: 95)
        XCTAssertEqual(clock.bucket, 0)

        clock.setWindowVisible(true)
        XCTAssertEqual(clock.bucket, 3)
        XCTAssertTrue(clock.hasScheduledTick)
    }

    func testPausedStartFreezesInitialBucketAcrossBoundaryUntilScrollEnds() {
        let scheduler = ManualScheduler(timestamp: 29)
        let clock = makeClock(scheduler)

        clock.start(pausedForScrolling: true)
        clock.setWindowVisible(true)
        XCTAssertTrue(clock.isScrolling)
        XCTAssertFalse(clock.hasScheduledTick)
        XCTAssertEqual(clock.bucket, 0)

        scheduler.advance(by: 31)
        XCTAssertEqual(clock.bucket, 0)
        XCTAssertFalse(clock.hasScheduledTick)

        clock.scrollDidEnd()
        XCTAssertFalse(clock.isScrolling)
        XCTAssertEqual(clock.bucket, 2)
        XCTAssertTrue(clock.hasScheduledTick)
    }

    func testRelativeTimeCacheRetainsOneGenerationPerItem() {
        let item = makeItem()
        let cache = HistoryItemPresentationCache.shared

        let first = cache.relativeTimeText(itemID: item.id, lastUsedAt: item.lastUsedAt, bucket: 10)
        let firstAgain = cache.relativeTimeText(itemID: item.id, lastUsedAt: item.lastUsedAt, bucket: 10)
        let second = cache.relativeTimeText(itemID: item.id, lastUsedAt: item.lastUsedAt, bucket: 11)

        XCTAssertEqual(first, firstAgain)
        XCTAssertFalse(second.isEmpty)
        XCTAssertEqual(cache.relativeTimeEntryCountForTesting, 1)
        XCTAssertEqual(cache.relativeTimeBucketForTesting(itemID: item.id), 11)
    }

    func testClockTickUpdatesTimeWithoutRebuildingTheInteractionHost() async {
        let item = makeItem()
        let scheduler = ManualScheduler(timestamp: 59)
        let clock = makeClock(scheduler)
        let row = HistoryItemView(
            item: item, isSelected: false, settings: .default, searchMatchContext: nil,
            onSelect: {}, onSelectOptimizedForCodex: {}, onSendViaAirDrop: {},
            onOpenContainingFolder: {}, onHoverSelect: { _ in }, onTogglePin: {}, onDelete: {},
            onUpdateNote: { _ in true },
            onOptimizeImage: { .init(result: .noChange, originalBytes: 0, optimizedBytes: 0) },
            getImageData: { nil },
            markdownWebViewController: MarkdownPreviewWebViewController(),
            interactionCoordinator: HistoryListInteractionCoordinator(),
            interactionSessionStore: HistoryItemInteractionSessionStore(),
            isContentRevisionCurrent: { _, _ in true },
            isImagePreviewPresented: false, isTextPreviewPresented: false, isFilePreviewPresented: false,
            requestPopover: { _ in }, requestPinPreview: { _, _, _ in }, dismissOtherPopovers: {}
        )
        let host = NSHostingView(rootView: row.environment(\.historyRelativeTimeClock, clock))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 80)
        clock.start()
        clock.setWindowVisible(true)
        defer { clock.stop() }

        await render(host, untilTimeBucket: 1, itemID: item.id)
        let beforeTick = HistoryItemView.bodyCountForTesting
        scheduler.advance(by: 31)
        await render(host, untilTimeBucket: 3, itemID: item.id)

        XCTAssertEqual(HistoryItemView.bodyCountForTesting, beforeTick)
    }

    private func render(_ host: NSView, untilTimeBucket bucket: Int64, itemID: UUID) async {
        let cache = HistoryItemPresentationCache.shared
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while cache.relativeTimeBucketForTesting(itemID: itemID) != bucket && Date() < deadline
        XCTAssertEqual(cache.relativeTimeBucketForTesting(itemID: itemID), bucket, "The time leaf rendered the current clock value")
    }

    private func makeClock(_ scheduler: ManualScheduler) -> HistoryRelativeTimeClock {
        HistoryRelativeTimeClock(
            now: { scheduler.now },
            schedule: { delay, action in scheduler.schedule(delay: delay, action: action) }
        )
    }

    private func makeItem() -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: "relative-time-item",
            plainText: "text",
            note: nil,
            appBundleID: "com.scopy.tests",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: Date(timeIntervalSince1970: 15),
            isPinned: false,
            sizeBytes: 4,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil
        )
    }
}
