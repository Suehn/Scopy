import AppKit
import Foundation

// MARK: - Scroll Performance Profiling (Debug/UITest)

@MainActor
public final class ScrollPerformanceProfile {
    private struct Config {
        let enabled: Bool
        let durationSeconds: TimeInterval
        let minSamples: Int
        let outputPath: String
        let dropThresholdMultiplier: Double
        let expectedFrameMs: Double?
        let maxSamples: Int
        let autoScrollEnabled: Bool
        let autoScrollStepPx: Double
        let autoScrollIntervalSeconds: TimeInterval

        static func load() -> Config {
            let env = ProcessInfo.processInfo.environment
            let enabled = parseBool(env["SCOPY_SCROLL_PROFILE"]) ?? false
            let durationSeconds = parseDouble(env["SCOPY_PROFILE_DURATION_SEC"]) ?? 6.0
            let minSamples = max(30, parseInt(env["SCOPY_PROFILE_MIN_SAMPLES"]) ?? 180)
            let outputPath = env["SCOPY_PROFILE_OUTPUT"] ?? "/tmp/scopy_scroll_profile.json"
            let dropThresholdMultiplier = parseDouble(env["SCOPY_PROFILE_DROP_THRESHOLD"]) ?? 1.5
            let expectedFrameMs = parseDouble(env["SCOPY_PROFILE_EXPECTED_FRAME_MS"])
            let maxSamples = max(500, parseInt(env["SCOPY_PROFILE_MAX_SAMPLES"]) ?? 2000)
            let autoScrollEnabled = parseBool(env["SCOPY_PROFILE_AUTO_SCROLL"]) ?? false
            let autoScrollStepPx = parseDouble(env["SCOPY_PROFILE_AUTO_SCROLL_STEP_PX"]) ?? 36.0
            let autoScrollIntervalSeconds = parseDouble(env["SCOPY_PROFILE_AUTO_SCROLL_INTERVAL_SEC"]) ?? (1.0 / 60.0)

            return Config(
                enabled: enabled,
                durationSeconds: durationSeconds,
                minSamples: minSamples,
                outputPath: outputPath,
                dropThresholdMultiplier: dropThresholdMultiplier,
                expectedFrameMs: expectedFrameMs,
                maxSamples: maxSamples,
                autoScrollEnabled: autoScrollEnabled,
                autoScrollStepPx: autoScrollStepPx,
                autoScrollIntervalSeconds: autoScrollIntervalSeconds
            )
        }

        private static func parseInt(_ value: String?) -> Int? {
            guard let value, !value.isEmpty else { return nil }
            return Int(value)
        }

        private static func parseDouble(_ value: String?) -> Double? {
            guard let value, !value.isEmpty else { return nil }
            return Double(value)
        }

        private static func parseBool(_ value: String?) -> Bool? {
            guard let value else { return nil }
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
    }

    struct MetricEvent: Sendable {
        let name: String
        let start: TimeInterval
        let end: TimeInterval
        let durationMs: Double
    }

    struct FrameSample: Sendable {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
        let intervalMs: Double
        let offsetDelta: Double?
        let scrollSpeed: Double?
        let isScrolling: Bool
    }

    private struct MetricAggregate {
        var count = 0
        var totalMs = 0.0
        var overlapMs = 0.0
        var maxMs = 0.0
        var frameIndexes: Set<Int> = []

        mutating func add(event: MetricEvent, overlapMs: Double, frameIndex: Int) {
            count += 1
            totalMs += event.durationMs
            self.overlapMs += overlapMs
            maxMs = max(maxMs, event.durationMs)
            frameIndexes.insert(frameIndex)
        }

        var payload: [String: Any] {
            [
                "count": count,
                "frame_count": frameIndexes.count,
                "total_ms": totalMs,
                "overlap_ms": overlapMs,
                "max_ms": maxMs
            ]
        }
    }

    public static let shared = ScrollPerformanceProfile()
    public nonisolated static let isEnabled: Bool = Config.load().enabled

    private let config: Config
    private weak var scrollView: NSScrollView?

    private var isScrolling = false
    private var startTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval?
    private var lastScrollOffset: CGFloat?
    private var expectedFrameMs: Double?
    private var dropCount = 0
    private var hasWritten = false
    private var autoScrollTimer: Timer?
    private var autoScrollDirection: CGFloat = 1
    private var mainRunLoopObserver: CFRunLoopObserver?
    private var mainRunLoopActiveStart: TimeInterval?

    private var frameIntervalsMs: [Double] = []
    private var scrollSpeedSamples: [Double] = []
    private var metricBuckets: [String: [Double]] = [:]
    private var metricEvents: [MetricEvent] = []
    private var frameSamples: [FrameSample] = []
    private var mainRunLoopActiveDurationsMs: [Double] = []
    private var mainRunLoopEvents: [MetricEvent] = []
    private var frameSequence = 0

    private init() {
        self.config = Config.load()
        self.expectedFrameMs = config.expectedFrameMs
    }

    public func attachScrollView(_ scrollView: NSScrollView) {
        guard config.enabled else { return }
        self.scrollView = scrollView
        startAutoScrollIfNeeded(scrollView)
    }

    public func scrollDidStart() {
        guard config.enabled else { return }
        isScrolling = true
        startMainRunLoopObserverIfNeeded()
        if startTimestamp == nil {
            startTimestamp = Date().timeIntervalSinceReferenceDate
        }
    }

    public func scrollDidEnd() {
        guard config.enabled else { return }
        isScrolling = false
    }

    public func recordFrameTick(_ date: Date) {
        guard config.enabled else { return }
        guard !hasWritten else { return }

        let now = date.timeIntervalSinceReferenceDate
        if startTimestamp == nil {
            guard !config.autoScrollEnabled else { return }
            startTimestamp = now
        }

        let currentOffset = scrollView?.contentView.bounds.origin.y
        let offsetDelta: Double? = {
            guard let currentOffset, let lastOffset = lastScrollOffset else { return nil }
            let delta = Double(abs(currentOffset - lastOffset))
            return delta > 0 ? delta : nil
        }()

        if let lastFrameTimestamp {
            let intervalMs = (now - lastFrameTimestamp) * 1000
            appendSample(intervalMs, to: &frameIntervalsMs, limit: config.maxSamples)
            updateExpectedFrameIfNeeded()
            if let expectedFrameMs, intervalMs > expectedFrameMs * config.dropThresholdMultiplier {
                dropCount += 1
            }

            if let delta = offsetDelta, intervalMs > 0 {
                let speed = delta / (intervalMs / 1000)
                appendSample(speed, to: &scrollSpeedSamples, limit: config.maxSamples)
            }

            let speed: Double? = {
                guard let delta = offsetDelta, intervalMs > 0 else { return nil }
                return delta / (intervalMs / 1000)
            }()
            appendFrameSample(
                FrameSample(
                    index: frameSequence,
                    start: lastFrameTimestamp,
                    end: now,
                    intervalMs: intervalMs,
                    offsetDelta: offsetDelta,
                    scrollSpeed: speed,
                    isScrolling: isScrolling
                )
            )
            frameSequence += 1
        }

        lastFrameTimestamp = now
        lastScrollOffset = currentOffset
        maybeFinalize(now: now)
    }

    public func recordMetric(name: String, elapsedMs: Double) {
        recordMetric(name: name, elapsedMs: elapsedMs, endedAt: Date().timeIntervalSinceReferenceDate)
    }

    private func recordMetric(name: String, elapsedMs: Double, endedAt: TimeInterval) {
        guard config.enabled else { return }
        let clampedElapsedMs = max(0, elapsedMs)
        var bucket = metricBuckets[name, default: []]
        appendSample(clampedElapsedMs, to: &bucket, limit: config.maxSamples)
        metricBuckets[name] = bucket
        appendMetricEvent(
            MetricEvent(
                name: name,
                start: endedAt - clampedElapsedMs / 1000,
                end: endedAt,
                durationMs: clampedElapsedMs
            )
        )
    }

    public nonisolated static func recordMetric(name: String, elapsedMs: Double) {
        guard isEnabled else { return }
        let endedAt = Date().timeIntervalSinceReferenceDate
        Task { @MainActor in
            shared.recordMetric(name: name, elapsedMs: elapsedMs, endedAt: endedAt)
        }
    }

    private func appendSample(_ value: Double, to array: inout [Double], limit: Int) {
        if array.count < limit {
            array.append(value)
        } else {
            array.removeFirst()
            array.append(value)
        }
    }

    private func appendMetricEvent(_ event: MetricEvent) {
        if metricEvents.count < config.maxSamples {
            metricEvents.append(event)
        } else {
            metricEvents.removeFirst()
            metricEvents.append(event)
        }
    }

    private func appendFrameSample(_ sample: FrameSample) {
        if frameSamples.count < config.maxSamples {
            frameSamples.append(sample)
        } else {
            frameSamples.removeFirst()
            frameSamples.append(sample)
        }
    }

    private func appendMainRunLoopEvent(_ event: MetricEvent) {
        if mainRunLoopEvents.count < config.maxSamples {
            mainRunLoopEvents.append(event)
        } else {
            mainRunLoopEvents.removeFirst()
            mainRunLoopEvents.append(event)
        }
    }

    private func updateExpectedFrameIfNeeded() {
        guard expectedFrameMs == nil else { return }
        let warmupCount = min(30, frameIntervalsMs.count)
        guard warmupCount >= 12 else { return }
        let sample = Array(frameIntervalsMs.prefix(warmupCount)).sorted()
        expectedFrameMs = percentile(sample, p: 50)
    }

    private func maybeFinalize(now: TimeInterval) {
        guard !hasWritten else { return }
        guard let startTimestamp else { return }
        let elapsed = now - startTimestamp
        guard elapsed >= config.durationSeconds else { return }
        guard frameIntervalsMs.count >= config.minSamples else { return }
        writeReport(elapsedSeconds: elapsed)
    }

    private func writeReport(elapsedSeconds: TimeInterval) {
        hasWritten = true
        stopAutoScrollIfNeeded()
        stopMainRunLoopObserverIfNeeded(at: Date().timeIntervalSinceReferenceDate)
        let frameStats = computeStats(frameIntervalsMs)
        let activeFrameIntervalsMs = frameSamples
            .filter(Self.isActiveFrame)
            .map(\.intervalMs)
        let activeFrameStats = computeStats(activeFrameIntervalsMs)
        let speedStats = computeStats(scrollSpeedSamples)
        let mainRunLoopStats = computeStats(mainRunLoopActiveDurationsMs)
        let expected = expectedFrameMs ?? 0
        let dropRatio = frameIntervalsMs.isEmpty ? 0 : Double(dropCount) / Double(frameIntervalsMs.count)
        let thresholdMs = expected * config.dropThresholdMultiplier
        let activeDropCount = expected > 0
            ? activeFrameIntervalsMs.filter { $0 > thresholdMs }.count
            : 0
        let activeDropRatio = activeFrameIntervalsMs.isEmpty
            ? 0
            : Double(activeDropCount) / Double(activeFrameIntervalsMs.count)

        var bucketStats: [String: [String: Double]] = [:]
        for (key, values) in metricBuckets {
            let stats = computeStats(values)
            bucketStats[key] = [
                "count": Double(stats.count),
                "p50": stats.p50,
                "p95": stats.p95,
                "avg": stats.avg
            ]
        }

        let env = ProcessInfo.processInfo.environment
        let longFrameAttribution = Self.buildLongFrameAttribution(
            frameSamples: frameSamples,
            metricEvents: metricEvents,
            expectedFrameMs: expected,
            dropThresholdMultiplier: config.dropThresholdMultiplier,
            maxFrameDetails: 12,
            timelineStart: startTimestamp
        )
        let mainThreadLongFrameAttribution = Self.buildLongFrameAttribution(
            frameSamples: frameSamples,
            metricEvents: mainRunLoopEvents,
            expectedFrameMs: expected,
            dropThresholdMultiplier: config.dropThresholdMultiplier,
            maxFrameDetails: 12,
            timelineStart: startTimestamp
        )
        let accessibilityTree = buildAccessibilitySnapshot()
        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "profile_scenario": env["SCOPY_PROFILE_SCENARIO"] ?? "",
            "duration_seconds": elapsedSeconds,
            "frame_ms": [
                "count": frameStats.count,
                "min": frameStats.min,
                "avg": frameStats.avg,
                "p50": frameStats.p50,
                "p95": frameStats.p95,
                "max": frameStats.max
            ],
            "expected_frame_ms": expected,
            "drop_ratio": dropRatio,
            "active_frame_ms": [
                "count": activeFrameStats.count,
                "min": activeFrameStats.min,
                "avg": activeFrameStats.avg,
                "p50": activeFrameStats.p50,
                "p95": activeFrameStats.p95,
                "max": activeFrameStats.max
            ],
            "active_drop_ratio": activeDropRatio,
            "scroll_speed_px_per_sec": [
                "count": speedStats.count,
                "min": speedStats.min,
                "avg": speedStats.avg,
                "p50": speedStats.p50,
                "p95": speedStats.p95,
                "max": speedStats.max
            ],
            "buckets_ms": bucketStats,
            "metric_event_count": metricEvents.count,
            "long_frame_attribution": longFrameAttribution,
            "main_runloop_active_ms": [
                "count": mainRunLoopStats.count,
                "min": mainRunLoopStats.min,
                "avg": mainRunLoopStats.avg,
                "p50": mainRunLoopStats.p50,
                "p95": mainRunLoopStats.p95,
                "max": mainRunLoopStats.max
            ],
            "main_runloop_event_count": mainRunLoopEvents.count,
            "main_thread_long_frame_attribution": mainThreadLongFrameAttribution,
            "accessibility_tree": accessibilityTree,
            "scroll_sample_health": [
                "scroll_view_attached": scrollView != nil,
                "frame_count": frameSamples.count,
                "active_frame_count": activeFrameStats.count,
                "moving_frame_count": frameSamples.filter { ($0.offsetDelta ?? 0) > 0 }.count,
                "live_scroll_frame_count": frameSamples.filter(\.isScrolling).count
            ],
            "config": [
                "mock_item_count": env["SCOPY_MOCK_ITEM_COUNT"] ?? "",
                "mock_image_count": env["SCOPY_MOCK_IMAGE_COUNT"] ?? "",
                "mock_text_length": env["SCOPY_MOCK_TEXT_LENGTH"] ?? "",
                "mock_show_thumbnails": env["SCOPY_MOCK_SHOW_THUMBNAILS"] ?? "",
                "profile_accessibility": env["SCOPY_PROFILE_ACCESSIBILITY"] ?? "",
                "profile_auto_scroll": env["SCOPY_PROFILE_AUTO_SCROLL"] ?? ""
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        let url = URL(fileURLWithPath: config.outputPath)
        try? data.write(to: url, options: .atomic)
    }

    static func buildLongFrameAttribution(
        frameSamples: [FrameSample],
        metricEvents: [MetricEvent],
        expectedFrameMs: Double,
        dropThresholdMultiplier: Double,
        maxFrameDetails: Int,
        timelineStart: TimeInterval?
    ) -> [String: Any] {
        guard expectedFrameMs > 0, dropThresholdMultiplier > 0 else {
            return [
                "threshold_ms": 0,
                "long_frame_count": 0,
                "metric_event_count": metricEvents.count,
                "total_frame_ms": 0,
                "attributed_union_ms": 0,
                "unattributed_ms": 0,
                "attribution_coverage_ratio": 0,
                "top_metrics": [],
                "frames": []
            ]
        }

        let thresholdMs = expectedFrameMs * dropThresholdMultiplier
        let longFrames = frameSamples.filter { sample in
            guard sample.intervalMs > thresholdMs else { return false }
            return isActiveFrame(sample)
        }
        let detailFrameIndexes = Set(
            longFrames
                .sorted { $0.intervalMs > $1.intervalMs }
                .prefix(maxFrameDetails)
                .map(\.index)
        )
        var aggregateByMetric: [String: MetricAggregate] = [:]
        var detailFrames: [[String: Any]] = []
        var totalLongFrameMs = 0.0
        var attributedUnionMs = 0.0

        for frame in longFrames {
            totalLongFrameMs += frame.intervalMs
            let eventUnionOverlapMs = unionOverlapMs(metricEvents, overlapping: frame)
            attributedUnionMs += eventUnionOverlapMs
            let frameAggregates = aggregateEvents(
                metricEvents,
                overlapping: frame,
                into: &aggregateByMetric
            )

            if detailFrameIndexes.contains(frame.index) {
                detailFrames.append(
                    framePayload(
                        frame,
                        thresholdMs: thresholdMs,
                        timelineStart: timelineStart,
                        eventUnionOverlapMs: eventUnionOverlapMs,
                        aggregates: frameAggregates
                    )
                )
            }
        }
        detailFrames.sort {
            (($0["interval_ms"] as? Double) ?? 0) > (($1["interval_ms"] as? Double) ?? 0)
        }

        let topMetrics = aggregateByMetric
            .sorted { lhs, rhs in
                if lhs.value.overlapMs == rhs.value.overlapMs {
                    return lhs.value.totalMs > rhs.value.totalMs
                }
                return lhs.value.overlapMs > rhs.value.overlapMs
            }
            .prefix(12)
            .map { name, aggregate -> [String: Any] in
                var payload = aggregate.payload
                payload["name"] = name
                return payload
            }

        let unattributedMs = max(0, totalLongFrameMs - attributedUnionMs)
        let attributionCoverageRatio = totalLongFrameMs > 0
            ? min(1, attributedUnionMs / totalLongFrameMs)
            : 0
        return [
            "threshold_ms": thresholdMs,
            "long_frame_count": longFrames.count,
            "metric_event_count": metricEvents.count,
            "total_frame_ms": totalLongFrameMs,
            "attributed_union_ms": attributedUnionMs,
            "unattributed_ms": unattributedMs,
            "attribution_coverage_ratio": attributionCoverageRatio,
            "top_metrics": Array(topMetrics),
            "frames": detailFrames
        ]
    }

    private static func isActiveFrame(_ sample: FrameSample) -> Bool {
        sample.isScrolling || (sample.offsetDelta ?? 0) > 0
    }

    private func startAutoScrollIfNeeded(_ scrollView: NSScrollView) {
        guard config.autoScrollEnabled else { return }
        guard autoScrollTimer == nil else { return }

        let interval = max(1.0 / 120.0, config.autoScrollIntervalSeconds)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self, weak scrollView] _ in
            Task { @MainActor in
                guard let self, let scrollView else { return }
                self.advanceAutoScroll(scrollView)
            }
        }
        autoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceAutoScroll(_ scrollView: NSScrollView) {
        guard config.enabled, !hasWritten else { return }
        guard let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard maxY > 0 else { return }

        if !isScrolling {
            scrollDidStart()
        }

        var nextY = clipView.bounds.origin.y + autoScrollDirection * config.autoScrollStepPx
        if nextY >= maxY {
            nextY = maxY
            autoScrollDirection = -1
        } else if nextY <= 0 {
            nextY = 0
            autoScrollDirection = 1
        }

        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func stopAutoScrollIfNeeded() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        if config.autoScrollEnabled {
            scrollDidEnd()
        }
    }

    private func startMainRunLoopObserverIfNeeded() {
        guard mainRunLoopObserver == nil else { return }

        mainRunLoopActiveStart = Date().timeIntervalSinceReferenceDate
        let activities = CFRunLoopActivity.entry.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue
        guard let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            0,
            { _, activity in
                guard Thread.isMainThread else { return }
                let rawActivity = activity.rawValue
                let timestamp = Date().timeIntervalSinceReferenceDate
                MainActor.assumeIsolated {
                    ScrollPerformanceProfile.shared.handleMainRunLoopActivity(
                        rawActivity: rawActivity,
                        at: timestamp
                    )
                }
            }
        ) else { return }

        mainRunLoopObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    private func stopMainRunLoopObserverIfNeeded(at timestamp: TimeInterval) {
        closeMainRunLoopActiveInterval(at: timestamp)
        if let observer = mainRunLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            mainRunLoopObserver = nil
        }
    }

    private func handleMainRunLoopActivity(rawActivity: CFOptionFlags, at timestamp: TimeInterval) {
        guard config.enabled, !hasWritten else { return }

        if rawActivity == CFRunLoopActivity.entry.rawValue
            || rawActivity == CFRunLoopActivity.afterWaiting.rawValue {
            if mainRunLoopActiveStart == nil {
                mainRunLoopActiveStart = timestamp
            }
            return
        }

        if rawActivity == CFRunLoopActivity.beforeWaiting.rawValue
            || rawActivity == CFRunLoopActivity.exit.rawValue {
            closeMainRunLoopActiveInterval(at: timestamp)
        }
    }

    private func closeMainRunLoopActiveInterval(at timestamp: TimeInterval) {
        guard let start = mainRunLoopActiveStart else { return }
        mainRunLoopActiveStart = nil

        let durationMs = max(0, (timestamp - start) * 1000)
        guard durationMs > 0 else { return }
        appendSample(durationMs, to: &mainRunLoopActiveDurationsMs, limit: config.maxSamples)
        appendMainRunLoopEvent(
            MetricEvent(
                name: "main.runloop_active_ms",
                start: start,
                end: timestamp,
                durationMs: durationMs
            )
        )
    }

    private static func aggregateEvents(
        _ events: [MetricEvent],
        overlapping frame: FrameSample,
        into globalAggregate: inout [String: MetricAggregate]
    ) -> [String: MetricAggregate] {
        var frameAggregate: [String: MetricAggregate] = [:]

        for event in events {
            guard event.end >= frame.start, event.start <= frame.end else { continue }
            let overlapSeconds = min(event.end, frame.end) - max(event.start, frame.start)
            let overlapMs = max(0, overlapSeconds * 1000)
            guard overlapMs > 0 || (event.end >= frame.start && event.end <= frame.end) else {
                continue
            }

            frameAggregate[event.name, default: MetricAggregate()]
                .add(event: event, overlapMs: overlapMs, frameIndex: frame.index)
            globalAggregate[event.name, default: MetricAggregate()]
                .add(event: event, overlapMs: overlapMs, frameIndex: frame.index)
        }

        return frameAggregate
    }

    private static func unionOverlapMs(_ events: [MetricEvent], overlapping frame: FrameSample) -> Double {
        var intervals: [(start: TimeInterval, end: TimeInterval)] = []
        intervals.reserveCapacity(events.count)

        for event in events {
            let start = max(event.start, frame.start)
            let end = min(event.end, frame.end)
            guard end > start else { continue }
            intervals.append((start: start, end: end))
        }

        let sortedIntervals = intervals.sorted { $0.start < $1.start }
        guard var current = sortedIntervals.first else {
            return 0
        }

        var totalSeconds = 0.0
        for interval in sortedIntervals.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                totalSeconds += current.end - current.start
                current = interval
            }
        }
        totalSeconds += current.end - current.start

        return min(frame.intervalMs, max(0, totalSeconds * 1000))
    }

    private static func framePayload(
        _ frame: FrameSample,
        thresholdMs: Double,
        timelineStart: TimeInterval?,
        eventUnionOverlapMs: Double,
        aggregates: [String: MetricAggregate]
    ) -> [String: Any] {
        let topEvents = aggregates
            .sorted { lhs, rhs in
                if lhs.value.overlapMs == rhs.value.overlapMs {
                    return lhs.value.totalMs > rhs.value.totalMs
                }
                return lhs.value.overlapMs > rhs.value.overlapMs
            }
            .prefix(8)
            .map { name, aggregate -> [String: Any] in
                var payload = aggregate.payload
                payload["name"] = name
                return payload
            }

        var payload: [String: Any] = [
            "index": frame.index,
            "interval_ms": frame.intervalMs,
            "threshold_ms": thresholdMs,
            "event_count": aggregates.values.reduce(0) { $0 + $1.count },
            "event_overlap_ms": aggregates.values.reduce(0) { $0 + $1.overlapMs },
            "event_union_overlap_ms": eventUnionOverlapMs,
            "unattributed_ms": max(0, frame.intervalMs - eventUnionOverlapMs),
            "attribution_coverage_ratio": frame.intervalMs > 0 ? min(1, eventUnionOverlapMs / frame.intervalMs) : 0,
            "is_scrolling": frame.isScrolling,
            "top_events": Array(topEvents)
        ]
        if let timelineStart {
            payload["start_ms"] = (frame.start - timelineStart) * 1000
            payload["end_ms"] = (frame.end - timelineStart) * 1000
        }
        if let offsetDelta = frame.offsetDelta {
            payload["offset_delta_px"] = offsetDelta
        }
        if let scrollSpeed = frame.scrollSpeed {
            payload["scroll_speed_px_per_sec"] = scrollSpeed
        }
        return payload
    }

    private func buildAccessibilitySnapshot() -> [String: Any] {
        guard let scrollView else {
            return [
                "available": false,
                "reason": "scroll_view_missing"
            ]
        }

        let start = CFAbsoluteTimeGetCurrent()
        let viewTree = Self.viewTreeSnapshot(root: scrollView)

        let axStart = CFAbsoluteTimeGetCurrent()
        let children = Self.accessibilityArray(from: scrollView, selectorName: "accessibilityChildren")
        let rows = Self.accessibilityArray(from: scrollView, selectorName: "accessibilityRows")
        let visibleRows = Self.accessibilityArray(from: scrollView, selectorName: "accessibilityVisibleRows")
        let axElapsedMs = (CFAbsoluteTimeGetCurrent() - axStart) * 1000
        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let visibleHeight = scrollView.contentView.bounds.height
        return [
            "available": true,
            "snapshot_ms": totalElapsedMs,
            "ax_query_ms": axElapsedMs,
            "ax_children_count": children.count,
            "ax_rows_count": rows.count,
            "ax_visible_rows_count": visibleRows.count,
            "document_height": Double(documentHeight),
            "visible_height": Double(visibleHeight),
            "view_tree": viewTree
        ]
    }

    private static func accessibilityArray(from object: NSObject, selectorName: String) -> [Any] {
        let selector = Selector((selectorName))
        guard object.responds(to: selector) else { return [] }
        guard let value = object.perform(selector)?.takeUnretainedValue() else { return [] }
        return value as? [Any] ?? []
    }

    private static func viewTreeSnapshot(root: NSView) -> [String: Any] {
        var viewCount = 0
        var maxDepth = 0
        var classCounts: [String: Int] = [:]

        func visit(_ view: NSView, depth: Int) {
            viewCount += 1
            maxDepth = max(maxDepth, depth)
            let className = String(describing: type(of: view))
            classCounts[className, default: 0] += 1
            for subview in view.subviews {
                visit(subview, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        let topClasses = classCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(12)
            .map { ["class": $0.key, "count": $0.value] }

        return [
            "view_count": viewCount,
            "max_depth": maxDepth,
            "top_classes": Array(topClasses)
        ]
    }

    private func computeStats(_ samples: [Double]) -> (count: Int, min: Double, max: Double, avg: Double, p50: Double, p95: Double) {
        guard !samples.isEmpty else { return (0, 0, 0, 0, 0, 0) }
        let sorted = samples.sorted()
        let count = sorted.count
        let minValue = sorted.first ?? 0
        let maxValue = sorted.last ?? 0
        let avg = sorted.reduce(0, +) / Double(count)
        let p50 = percentile(sorted, p: 50)
        let p95 = percentile(sorted, p: 95)
        return (count, minValue, maxValue, avg, p50, p95)
    }

    private func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count) * p / 100)
        return sorted[min(index, sorted.count - 1)]
    }
}
