import AppKit
import XCTest
import ScopyKit
@testable import ScopyUISupport

@MainActor
final class ScrollPerformanceTests: XCTestCase {

    private final class TestScroller: NSScroller {
        var reportedPart: NSScroller.Part = .knob

        override func testPart(_ point: NSPoint) -> NSScroller.Part {
            reportedPart
        }
    }

    @MainActor
    private struct ScrollbarFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let observer: ListLiveScrollObserverView.ObserverView
        let verticalScroller: TestScroller
        let horizontalScroller: TestScroller

        var verticalPointInWindow: NSPoint {
            verticalScroller.convert(
                NSPoint(x: verticalScroller.bounds.midX, y: verticalScroller.bounds.midY),
                to: nil
            )
        }

        var horizontalPointInWindow: NSPoint {
            horizontalScroller.convert(
                NSPoint(x: horizontalScroller.bounds.midX, y: horizontalScroller.bounds.midY),
                to: nil
            )
        }

        var documentPointInWindow: NSPoint {
            scrollView.contentView.convert(
                NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY),
                to: nil
            )
        }
    }

    private final class StubClipboardService: ClipboardServiceProtocol {
        var eventStream: AsyncStream<ClipboardEvent> { AsyncStream { $0.finish() } }

        func start() async throws {}
        func stop() {}
        func stopAndWait() async {}
        func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] { [] }
        func search(query: SearchRequest) async throws -> SearchResultPage {
            SearchResultPage(hits: [], total: 0, hasMore: false, coverage: .complete)
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

        let samples = PerformanceHelpers.collectTimeSamples(
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

    func testScrollbarHitTestingClassifiesVisibleVerticalAndHorizontalScrollers() {
        let fixture = makeScrollbarFixture()

        XCTAssertEqual(
            ListLiveScrollObserverView.ObserverView.scrollbarAxis(
                in: fixture.scrollView,
                eventWindow: fixture.window,
                locationInWindow: fixture.verticalPointInWindow
            ),
            .vertical
        )
        XCTAssertEqual(
            ListLiveScrollObserverView.ObserverView.scrollbarAxis(
                in: fixture.scrollView,
                eventWindow: fixture.window,
                locationInWindow: fixture.horizontalPointInWindow
            ),
            .horizontal
        )
    }

    func testScrollbarHitTestingRejectsDocumentHiddenNoPartAndOtherWindow() {
        let fixture = makeScrollbarFixture()

        XCTAssertNil(
            ListLiveScrollObserverView.ObserverView.scrollbarAxis(
                in: fixture.scrollView,
                eventWindow: fixture.window,
                locationInWindow: fixture.documentPointInWindow
            )
        )

        fixture.verticalScroller.isHidden = true
        XCTAssertNil(
            ListLiveScrollObserverView.ObserverView.scrollbarAxis(
                in: fixture.scrollView,
                eventWindow: fixture.window,
                locationInWindow: fixture.verticalPointInWindow
            )
        )

        fixture.verticalScroller.isHidden = false
        fixture.verticalScroller.reportedPart = .noPart
        XCTAssertNil(
            ListLiveScrollObserverView.ObserverView.scrollbarAxis(
                in: fixture.scrollView,
                eventWindow: fixture.window,
                locationInWindow: fixture.verticalPointInWindow
            )
        )

        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        XCTAssertNil(
            ListLiveScrollObserverView.ObserverView.scrollbarAxis(
                in: fixture.scrollView,
                eventWindow: otherWindow,
                locationInWindow: fixture.horizontalPointInWindow
            )
        )
    }

    func testPointerReducerIgnoresOrdinaryContentAndUnmatchedMouseUp() {
        let fixture = makeScrollbarFixture()
        let coordinator = HistoryListInteractionCoordinator()
        fixture.observer.interactionCoordinator = coordinator

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.documentPointInWindow
        )
        XCTAssertFalse(coordinator.isPointerInteractionActive)

        fixture.observer.handlePointerInteraction(
            type: .leftMouseUp,
            eventWindow: fixture.window,
            locationInWindow: fixture.documentPointInWindow
        )
        XCTAssertFalse(coordinator.isPointerInteractionActive)
        XCTAssertEqual(coordinator.passivePathSnapshot.pointerInteractionCount, 0)
    }

    func testPointerReducerPairsScrollerMouseDownAndMouseUp() {
        let fixture = makeScrollbarFixture()
        let coordinator = HistoryListInteractionCoordinator()
        fixture.observer.interactionCoordinator = coordinator

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.verticalPointInWindow
        )
        XCTAssertTrue(coordinator.isPointerInteractionActive)
        XCTAssertEqual(coordinator.passivePathSnapshot.pointerInteractionCount, 1)

        fixture.observer.handlePointerInteraction(
            type: .leftMouseUp,
            eventWindow: fixture.window,
            locationInWindow: fixture.documentPointInWindow
        )
        XCTAssertFalse(coordinator.isPointerInteractionActive)
        XCTAssertEqual(coordinator.passivePathSnapshot.pointerInteractionCount, 0)
    }

    func testPointerOwnershipEndsOnObserverDetach() {
        let fixture = makeScrollbarFixture()
        let coordinator = HistoryListInteractionCoordinator()
        fixture.observer.interactionCoordinator = coordinator

        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.horizontalPointInWindow
        )
        XCTAssertTrue(coordinator.isPointerInteractionActive)

        fixture.observer.removeFromSuperview()

        XCTAssertFalse(coordinator.isPointerInteractionActive)
        XCTAssertEqual(coordinator.passivePathSnapshot.pointerInteractionCount, 0)
    }

    func testLiveScrollEndCleansUpOwnedPointerWhenMouseUpIsConsumed() {
        let fixture = makeScrollbarFixture()
        let coordinator = HistoryListInteractionCoordinator()
        fixture.observer.interactionCoordinator = coordinator
        fixture.observer.pressedMouseButtonsProvider = { 0 }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: fixture.scrollView
        )
        fixture.observer.handlePointerInteraction(
            type: .leftMouseDown,
            eventWindow: fixture.window,
            locationInWindow: fixture.verticalPointInWindow
        )
        XCTAssertTrue(coordinator.isPointerInteractionActive)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: fixture.scrollView
        )

        XCTAssertFalse(coordinator.isPointerInteractionActive)
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

    func testBoundedRingBufferWrapsInChronologicalOrder() {
        var buffer = BoundedRingBuffer<Int>(capacity: 3)

        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.chronologicalValues, [1, 2])
        XCTAssertEqual(buffer.retainedCount, 2)
        XCTAssertEqual(buffer.totalCount, 2)
        XCTAssertEqual(buffer.overwrittenCount, 0)

        buffer.append(3)
        buffer.append(4)
        buffer.append(5)

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.retainedCount, 3)
        XCTAssertEqual(buffer.totalCount, 5)
        XCTAssertEqual(buffer.overwrittenCount, 2)
        XCTAssertEqual(buffer.chronologicalValues, [3, 4, 5])
    }

    func testTimingSamplesKeepExactWholeRunTotalsAcrossTruncationAndReset() {
        var samples = ScrollProfileTimingSamples(capacity: 2)

        samples.append(1.25)
        samples.append(2.5)
        samples.append(4.0)

        XCTAssertEqual(samples.chronologicalValues, [2.5, 4.0])
        XCTAssertEqual(samples.retainedCount, 2)
        XCTAssertEqual(samples.totalCount, 3)
        XCTAssertEqual(samples.overwrittenCount, 1)
        XCTAssertEqual(samples.totalMs, 7.75, accuracy: 0.0001)

        samples.reset()
        XCTAssertEqual(samples.chronologicalValues, [])
        XCTAssertEqual(samples.retainedCount, 0)
        XCTAssertEqual(samples.totalCount, 0)
        XCTAssertEqual(samples.overwrittenCount, 0)
        XCTAssertEqual(samples.totalMs, 0, accuracy: 0.0001)
    }

    func testFixedWorkloadCallbackSequencerExcludesWarmupAndCapturesFinalCommandResponse() {
        var sequencer = FixedWorkloadCallbackSequencer(
            targetCommandCount: 3,
            hasWarmup: true
        )

        XCTAssertEqual(sequencer.nextTickAction(), .warm)
        sequencer.warmupDidComplete()
        XCTAssertEqual(sequencer.nextTickAction(), .settleBeforeMeasurement)
        XCTAssertEqual(sequencer.preMeasurementSettleCallbackCount, 1)

        XCTAssertEqual(sequencer.nextTickAction(), .beginMeasurementAndIssueFirstCommand)
        sequencer.commandDidIssue()
        XCTAssertEqual(sequencer.issuedCommandCount, 1)
        XCTAssertEqual(sequencer.measuredCommandResponseCount, 0)

        for expectedResponse in 1...2 {
            XCTAssertEqual(sequencer.nextTickAction(), .captureResponseAndIssueNextCommand)
            sequencer.commandResponseDidMeasure(final: false)
            XCTAssertEqual(sequencer.measuredCommandResponseCount, expectedResponse)
            sequencer.commandDidIssue()
        }

        XCTAssertEqual(sequencer.issuedCommandCount, 3)
        XCTAssertEqual(sequencer.phase, .postMeasurementSettle)
        XCTAssertEqual(sequencer.nextTickAction(), .captureFinalResponseAndComplete)
        sequencer.commandResponseDidMeasure(final: true)

        XCTAssertEqual(sequencer.measuredCommandResponseCount, 3)
        XCTAssertEqual(sequencer.preMeasurementSettleCallbackCount, 1)
        XCTAssertEqual(sequencer.postMeasurementSettleCallbackCount, 1)
        XCTAssertEqual(sequencer.phase, .finished)
        XCTAssertEqual(sequencer.nextTickAction(), .none)
    }

    func testFixedMeasurementTimingWindowRejectsWarmupTailAndKeepsFinalCommandWork() {
        let measurementStart = 10.0
        let warmupTail = ScrollPerformanceProfile.TimingEvent(
            name: "warmup.tail",
            start: 9.9,
            end: 10.1,
            durationMs: 200
        )
        let finalCommandWork = ScrollPerformanceProfile.TimingEvent(
            name: "command.final",
            start: 19.99,
            end: 20.0,
            durationMs: 10
        )

        XCTAssertFalse(
            ScrollPerformanceProfile.timingEventBelongsToFixedMeasurement(
                warmupTail,
                startingAt: measurementStart,
                measurementCompleted: false
            )
        )
        XCTAssertTrue(
            ScrollPerformanceProfile.timingEventBelongsToFixedMeasurement(
                finalCommandWork,
                startingAt: measurementStart,
                measurementCompleted: false
            )
        )
        XCTAssertFalse(
            ScrollPerformanceProfile.timingEventBelongsToFixedMeasurement(
                finalCommandWork,
                startingAt: measurementStart,
                measurementCompleted: true
            )
        )
    }

    func testMeasurementEpochAdvancesAndClosesOnlyMatchingGeneration() {
        let epoch = ScrollProfileMeasurementEpoch()
        XCTAssertEqual(epoch.snapshot(), .init(generation: 0, measurementStart: nil))

        let first = epoch.begin(at: 10)
        let second = epoch.begin(at: 20)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(second, .init(generation: 2, measurementStart: 20))

        epoch.close(generation: first.generation)
        XCTAssertEqual(epoch.snapshot(), second)
        epoch.close(generation: second.generation)
        XCTAssertEqual(epoch.snapshot(), .init(generation: 2, measurementStart: nil))
    }

    func testMeasurementEpochSerializesNewGenerationWithQueueReopen() async {
        let epoch = ScrollProfileMeasurementEpoch()
        let ingress = ScrollProfileSerializedEventBuffer<UInt64>()
        _ = ingress.closeAndTakePendingForFinalization()
        let transitionEntered = DispatchSemaphore(value: 0)
        let allowQueueReopen = DispatchSemaphore(value: 0)
        let producerStarted = DispatchSemaphore(value: 0)

        let beginTask = Task.detached { () -> UInt64 in
            let transition = epoch.begin(at: 10, whileLocked: {
                _ = ingress.closeAndTakePendingForFinalization()
                transitionEntered.signal()
                allowQueueReopen.wait()
                ingress.reopenDiscardingPending()
            })
            return transition.snapshot.generation
        }

        guard Self.waitForSignal(transitionEntered, timeout: .now() + 1) else {
            allowQueueReopen.signal()
            XCTFail("Measurement transition did not reach its queue boundary")
            _ = await beginTask.value
            return
        }

        let producerTask = Task.detached { () -> (generation: UInt64, enqueued: Bool) in
            producerStarted.signal()
            return epoch.withSnapshot { snapshot in
                (
                    generation: snapshot.generation,
                    enqueued: ingress.enqueue(snapshot.generation)
                )
            }
        }
        guard Self.waitForSignal(producerStarted, timeout: .now() + 1) else {
            allowQueueReopen.signal()
            XCTFail("Metric producer did not reach the epoch boundary")
            _ = await beginTask.value
            _ = await producerTask.value
            return
        }

        allowQueueReopen.signal()
        let beginGeneration = await beginTask.value
        let producer = await producerTask.value

        XCTAssertEqual(beginGeneration, 1)
        XCTAssertEqual(producer.generation, beginGeneration)
        XCTAssertTrue(producer.enqueued)
        XCTAssertEqual(ingress.takeNextBatch()?.elements, [beginGeneration])
    }

    nonisolated private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    func testExecutableFingerprintHashesExactFileBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-profile-executable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        XCTAssertEqual(
            ScrollPerformanceProfile.executableFingerprint(at: url),
            "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testStructuralCountersAccumulateWhileGaugesReplace() {
        var metrics = ScrollProfileStructuralMetrics()

        metrics.registerCounter(name: "session.created")
        metrics.incrementCounter(name: "session.created")
        metrics.incrementCounter(name: "session.created", by: 2)
        metrics.incrementCounter(name: "session.created", by: -1)
        metrics.registerCounter(name: "session.never-created")
        metrics.setGauge(name: "active.slot.count", value: 1)
        metrics.setGauge(name: "active.slot.count", value: 0)
        metrics.recordMaximumGauge(name: "active.slot.max", value: 1)
        metrics.recordMaximumGauge(name: "active.slot.max", value: 0)

        XCTAssertEqual(metrics.counters["session.created"], 3)
        XCTAssertEqual(metrics.counters["session.never-created"], 0)
        XCTAssertEqual(metrics.gauges["active.slot.count"], 0)
        XCTAssertEqual(metrics.gauges["active.slot.max"], 1)
    }

    func testFixedDatasetMetadataSerializesValidatorKeys() {
        let metadata = ScrollProfileDatasetMetadata(
            schema: "history-profile-dataset-v1",
            datasetID: "fixed-warm-text-v1",
            fingerprint: "sha256:" + String(repeating: "a", count: 64),
            itemCount: 50,
            textItemCount: 50,
            imageItemCount: 0,
            pinnedItemCount: 2,
            uniqueItemIDCount: 50,
            minimumTextUTF8Bytes: 4_096,
            maximumTextUTF8Bytes: 4_096
        )

        XCTAssertEqual(metadata.jsonPayload["schema"] as? String, "history-profile-dataset-v1")
        XCTAssertEqual(metadata.jsonPayload["id"] as? String, "fixed-warm-text-v1")
        XCTAssertEqual(metadata.jsonPayload["item_count"] as? Int, 50)
        XCTAssertEqual(metadata.jsonPayload["pinned_item_count"] as? Int, 2)
        XCTAssertEqual(metadata.jsonPayload["text_utf8_bytes_min"] as? Int, 4_096)
        XCTAssertEqual(metadata.jsonPayload["text_utf8_bytes_max"] as? Int, 4_096)
        XCTAssertEqual(ScrollPerformanceProfile.fixedWorkloadRequiredCounterNames.count, 14)
    }

    func testSerializedMetricIngressSchedulesOneDrainForAnOrderedBatch() {
        let ingress = ScrollProfileSerializedEventBuffer<Int>()

        XCTAssertTrue(ingress.enqueue(1))
        XCTAssertFalse(ingress.enqueue(2))
        XCTAssertFalse(ingress.enqueue(3))
        let firstBatch = ingress.takeNextBatch()
        XCTAssertEqual(firstBatch?.elements, [1, 2, 3])
        XCTAssertEqual(firstBatch?.overflow, ScrollProfileIngressOverflowStats())
        XCTAssertNil(ingress.takeNextBatch())

        XCTAssertTrue(ingress.enqueue(4))
        XCTAssertEqual(ingress.takeNextBatch()?.elements, [4])
        XCTAssertNil(ingress.takeNextBatch())
    }

    func testSerializedMetricIngressFinalizationAtomicallyDrainsAndCloses() {
        let ingress = ScrollProfileSerializedEventBuffer<Int>()

        XCTAssertTrue(ingress.enqueue(10))
        XCTAssertFalse(ingress.enqueue(20))
        XCTAssertEqual(ingress.closeAndTakePendingForFinalization().elements, [10, 20])

        // A producer crossing the ingress boundary after close is post-completion and rejected.
        XCTAssertFalse(ingress.enqueue(30))
        // The already-scheduled main-actor drainer safely retires after finalization drained it.
        XCTAssertNil(ingress.takeNextBatch())

        ingress.reopenDiscardingPending()
        XCTAssertTrue(ingress.enqueue(40))
        XCTAssertEqual(ingress.closeAndTakePendingForFinalization().elements, [40])
    }

    func testSerializedMetricIngressBoundsConcurrentOverflowAndReportsDrops() {
        let ingress = ScrollProfileSerializedEventBuffer<Int>(capacity: 8)

        DispatchQueue.concurrentPerform(iterations: 2_000) { value in
            _ = ingress.enqueue(value)
        }

        let batch = ingress.closeAndTakePendingForFinalization()
        XCTAssertEqual(batch.elements.count, 8)
        XCTAssertEqual(batch.overflow.coalescedRecordCount, 0)
        XCTAssertEqual(batch.overflow.droppedRecordCount, 1_992)
    }

    func testSerializedMetricIngressCanCoalesceWithoutLosingCounterTotals() {
        let ingress = ScrollProfileSerializedEventBuffer<Int>(
            capacity: 1,
            overflowHandler: { pending, incoming in
                pending[0] += incoming
                return .coalesced
            }
        )

        XCTAssertTrue(ingress.enqueue(1))
        XCTAssertFalse(ingress.enqueue(2))
        XCTAssertFalse(ingress.enqueue(3))

        let batch = ingress.closeAndTakePendingForFinalization()
        XCTAssertEqual(batch.elements, [6])
        XCTAssertEqual(batch.overflow.coalescedRecordCount, 2)
        XCTAssertEqual(batch.overflow.droppedRecordCount, 0)
    }

    func testSerializedMetricIngressSurvivesConcurrentEnqueueCloseAndReopen() {
        let ingress = ScrollProfileSerializedEventBuffer<Int>(capacity: 32)

        DispatchQueue.concurrentPerform(iterations: 4_000) { value in
            switch value % 41 {
            case 0:
                _ = ingress.closeAndTakePendingForFinalization()
            case 1:
                ingress.reopenDiscardingPending()
            default:
                _ = ingress.enqueue(value)
            }
        }

        _ = ingress.closeAndTakePendingForFinalization()
        XCTAssertFalse(ingress.enqueue(-1))
        ingress.reopenDiscardingPending()
        XCTAssertTrue(ingress.enqueue(99_999))
        let finalBatch = ingress.closeAndTakePendingForFinalization()
        XCTAssertEqual(finalBatch.elements, [99_999])
        XCTAssertEqual(finalBatch.overflow, ScrollProfileIngressOverflowStats())
    }

    func testAnimationCallbackMetricNamesAndThresholdMathAreExplicit() throws {
        let base = Date().timeIntervalSinceReferenceDate
        let samples = [
            ScrollPerformanceProfile.AnimationCallbackSample(
                index: 0,
                start: base,
                end: base + 0.008,
                intervalMs: 8,
                offsetDelta: nil,
                scrollSpeed: nil,
                isScrolling: false
            ),
            ScrollPerformanceProfile.AnimationCallbackSample(
                index: 1,
                start: base + 0.008,
                end: base + 0.024,
                intervalMs: 16,
                offsetDelta: 10,
                scrollSpeed: 625,
                isScrolling: true
            ),
            ScrollPerformanceProfile.AnimationCallbackSample(
                index: 2,
                start: base + 0.024,
                end: base + 0.056,
                intervalMs: 32,
                offsetDelta: 20,
                scrollSpeed: 625,
                isScrolling: true
            )
        ]

        let payload = ScrollPerformanceProfile.buildAnimationCallbackMetricPayload(
            intervalsMs: [8, 16, 32],
            samples: samples,
            expectedIntervalMs: 10,
            thresholdMultiplier: 1.5
        )

        let callbackStats = try XCTUnwrap(
            payload[ScrollPerformanceProfile.MetricName.animationCallbackInterval] as? [String: Any]
        )
        let activeCallbackStats = try XCTUnwrap(
            payload[ScrollPerformanceProfile.MetricName.activeAnimationCallbackInterval] as? [String: Any]
        )
        XCTAssertEqual(callbackStats["count"] as? Int, 3)
        XCTAssertEqual(callbackStats["p95"] as? Double, 32)
        XCTAssertEqual(activeCallbackStats["count"] as? Int, 2)
        XCTAssertEqual(
            payload[ScrollPerformanceProfile.MetricName.animationCallbackOverThresholdRatio] as? Double ?? 0,
            2.0 / 3.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            payload[ScrollPerformanceProfile.MetricName.activeAnimationCallbackOverThresholdRatio] as? Double ?? 0,
            1,
            accuracy: 0.0001
        )

        let legacyFrameStats = try XCTUnwrap(payload["frame_ms"] as? [String: Any])
        let legacyActiveFrameStats = try XCTUnwrap(payload["active_frame_ms"] as? [String: Any])
        XCTAssertEqual(legacyFrameStats["p95"] as? Double, callbackStats["p95"] as? Double)
        XCTAssertEqual(payload["expected_frame_ms"] as? Double, 10)
        XCTAssertEqual(payload["drop_ratio"] as? Double ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(legacyActiveFrameStats["count"] as? Int, 2)
        XCTAssertEqual(payload["active_drop_ratio"] as? Double ?? 0, 1, accuracy: 0.0001)
        let semantics = ScrollPerformanceProfile.metricSemanticsPayload
        let intervalSemantics = try XCTUnwrap(
            semantics[ScrollPerformanceProfile.MetricName.animationCallbackInterval] as? String
        )
        XCTAssertTrue(intervalSemantics.contains("NSScreen CADisplayLink"))
        XCTAssertTrue(intervalSemantics.contains("TimelineView(.animation)"))
        XCTAssertTrue(intervalSemantics.contains("not presented-frame"))
    }

    func testAsynchronouslyQueuedTimingEventKeepsOriginalCompletionWindow() async throws {
        let base = Date().timeIntervalSinceReferenceDate
        let event = ScrollPerformanceProfile.TimingEvent(
            name: "async.completed_ms",
            elapsedMs: 10,
            endedAt: base + 0.040
        )

        // Static recordTiming captures this event before it queues MainActor delivery.
        // Suspending here models that delivery delay without changing the source window.
        await Task.yield()

        let callback = ScrollPerformanceProfile.AnimationCallbackSample(
            index: 0,
            start: base + 0.020,
            end: base + 0.050,
            intervalMs: 30,
            offsetDelta: 10,
            scrollSpeed: 333,
            isScrolling: true
        )

        XCTAssertEqual(event.start, base + 0.030, accuracy: 0.000_001)
        XCTAssertEqual(event.end, base + 0.040, accuracy: 0.000_001)

        let attribution = ScrollPerformanceProfile.buildLongAnimationCallbackAttribution(
            callbackSamples: [callback],
            timingEvents: [event],
            expectedCallbackIntervalMs: 10,
            thresholdMultiplier: 1.5,
            maxCallbackDetails: 1,
            timelineStart: base
        )
        XCTAssertEqual(attribution["long_callback_count"] as? Int, 1)
        XCTAssertEqual(attribution["timing_event_count"] as? Int, 1)
        XCTAssertEqual(attribution["attributed_union_ms"] as? Double ?? 0, 10, accuracy: 0.1)
    }

    func testLegacyLongFrameAliasesPreserveExistingScriptContract() throws {
        let base = Date().timeIntervalSinceReferenceDate
        let canonical = ScrollPerformanceProfile.buildLongAnimationCallbackAttribution(
            callbackSamples: [
                ScrollPerformanceProfile.AnimationCallbackSample(
                    index: 4,
                    start: base,
                    end: base + 0.040,
                    intervalMs: 40,
                    offsetDelta: 20,
                    scrollSpeed: 500,
                    isScrolling: true
                )
            ],
            timingEvents: [
                ScrollPerformanceProfile.TimingEvent(
                    name: "row.body_ms",
                    start: base + 0.010,
                    end: base + 0.020,
                    durationMs: 10
                )
            ],
            expectedCallbackIntervalMs: 16,
            thresholdMultiplier: 1.5,
            maxCallbackDetails: 1,
            timelineStart: base
        )
        let legacy = ScrollPerformanceProfile.legacyLongFrameAttribution(from: canonical)

        XCTAssertEqual(legacy["long_frame_count"] as? Int, 1)
        XCTAssertEqual(legacy["metric_event_count"] as? Int, 1)
        XCTAssertEqual(legacy["total_frame_ms"] as? Double ?? 0, 40, accuracy: 0.001)

        let topMetrics = try XCTUnwrap(legacy["top_metrics"] as? [[String: Any]])
        XCTAssertEqual(topMetrics.first?["frame_count"] as? Int, 1)
        let frames = try XCTUnwrap(legacy["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.first?["index"] as? Int, 4)
    }

    func testLongCallbackAttributionUsesOverlappingTimingWindows() throws {
        let base = Date().timeIntervalSinceReferenceDate
        let callbacks = [
            ScrollPerformanceProfile.AnimationCallbackSample(
                index: 0,
                start: base,
                end: base + 0.016,
                intervalMs: 16,
                offsetDelta: nil,
                scrollSpeed: nil,
                isScrolling: false
            ),
            ScrollPerformanceProfile.AnimationCallbackSample(
                index: 1,
                start: base + 0.016,
                end: base + 0.066,
                intervalMs: 50,
                offsetDelta: 100,
                scrollSpeed: 2_000,
                isScrolling: true
            ),
            ScrollPerformanceProfile.AnimationCallbackSample(
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
            ScrollPerformanceProfile.TimingEvent(
                name: "row.display_model_ms",
                start: base + 0.020,
                end: base + 0.040,
                durationMs: 20
            ),
            ScrollPerformanceProfile.TimingEvent(
                name: "text.markdown_detect_ms",
                start: base + 0.025,
                end: base + 0.035,
                durationMs: 10
            ),
            ScrollPerformanceProfile.TimingEvent(
                name: "image.thumbnail_imageio_decode_ms",
                start: base + 0.070,
                end: base + 0.080,
                durationMs: 10
            ),
            ScrollPerformanceProfile.TimingEvent(
                name: "idle.metric_ms",
                start: base + 0.090,
                end: base + 0.130,
                durationMs: 40
            )
        ]

        let attribution = ScrollPerformanceProfile.buildLongAnimationCallbackAttribution(
            callbackSamples: callbacks,
            timingEvents: events,
            expectedCallbackIntervalMs: 16.667,
            thresholdMultiplier: 1.5,
            maxCallbackDetails: 4,
            timelineStart: base
        )

        XCTAssertEqual(attribution["long_callback_count"] as? Int, 1)
        XCTAssertEqual(attribution["total_callback_interval_ms"] as? Double ?? 0, 50, accuracy: 0.1)
        XCTAssertEqual(attribution["attributed_union_ms"] as? Double ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(attribution["unattributed_ms"] as? Double ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(attribution["attribution_coverage_ratio"] as? Double ?? 0, 0.4, accuracy: 0.01)

        let topMetrics = try XCTUnwrap(attribution["top_metrics"] as? [[String: Any]])
        let rowMetric = try XCTUnwrap(topMetrics.first { $0["name"] as? String == "row.display_model_ms" })
        let markdownMetric = try XCTUnwrap(topMetrics.first { $0["name"] as? String == "text.markdown_detect_ms" })
        XCTAssertNil(topMetrics.first { $0["name"] as? String == "idle.metric_ms" })
        XCTAssertEqual(rowMetric["count"] as? Int, 1)
        XCTAssertEqual(rowMetric["callback_count"] as? Int, 1)
        XCTAssertEqual(rowMetric["overlap_ms"] as? Double ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(markdownMetric["overlap_ms"] as? Double ?? 0, 10, accuracy: 0.1)

        let detailCallbacks = try XCTUnwrap(attribution["callbacks"] as? [[String: Any]])
        let detailCallback = try XCTUnwrap(detailCallbacks.first)
        XCTAssertEqual(detailCallback["callback_index"] as? Int, 1)
        XCTAssertEqual(detailCallback["event_count"] as? Int, 2)
        XCTAssertEqual(detailCallback["event_overlap_ms"] as? Double ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(detailCallback["event_union_overlap_ms"] as? Double ?? 0, 20, accuracy: 0.1)
        XCTAssertEqual(detailCallback["unattributed_ms"] as? Double ?? 0, 30, accuracy: 0.1)
        XCTAssertEqual(detailCallback["start_ms"] as? Double ?? 0, 16, accuracy: 0.1)
        XCTAssertEqual(detailCallback["end_ms"] as? Double ?? 0, 66, accuracy: 0.1)
    }

    private func makeObserver() -> (ListLiveScrollObserverView.ObserverView, NSScrollView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let observer = ListLiveScrollObserverView.ObserverView(frame: .zero)
        scrollView.contentView.addSubview(observer)
        observer.attachIfNeeded()
        return (observer, scrollView)
    }

    private func makeScrollbarFixture() -> ScrollbarFixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        window.contentView = contentView

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 300, height: 220))
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let verticalScroller = TestScroller()
        let horizontalScroller = TestScroller()
        scrollView.verticalScroller = verticalScroller
        scrollView.horizontalScroller = horizontalScroller
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        contentView.addSubview(scrollView)
        scrollView.tile()
        contentView.layoutSubtreeIfNeeded()

        let observer = ListLiveScrollObserverView.ObserverView(frame: .zero)
        scrollView.contentView.addSubview(observer)
        observer.attachIfNeeded()

        return ScrollbarFixture(
            window: window,
            scrollView: scrollView,
            observer: observer,
            verticalScroller: verticalScroller,
            horizontalScroller: horizontalScroller
        )
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
