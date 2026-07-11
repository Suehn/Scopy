import AppKit
import CryptoKit
import Foundation
import QuartzCore

struct BoundedRingBuffer<Element> {
    let capacity: Int

    private var storage: [Element] = []
    private var nextWriteIndex = 0
    private(set) var totalCount = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int {
        storage.count
    }

    var retainedCount: Int {
        storage.count
    }

    var overwrittenCount: Int {
        max(0, totalCount - storage.count)
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    mutating func append(_ value: Element) {
        totalCount += 1
        guard storage.count == capacity else {
            storage.append(value)
            return
        }

        storage[nextWriteIndex] = value
        nextWriteIndex = (nextWriteIndex + 1) % capacity
    }

    /// Returns the retained values from oldest to newest.
    var chronologicalValues: [Element] {
        guard storage.count == capacity, nextWriteIndex > 0 else {
            return storage
        }

        var values: [Element] = []
        values.reserveCapacity(storage.count)
        values.append(contentsOf: storage[nextWriteIndex...])
        values.append(contentsOf: storage[..<nextWriteIndex])
        return values
    }
}

struct ScrollProfileTimingSamples {
    let capacity: Int
    private var buffer: BoundedRingBuffer<Double>
    private(set) var totalMs = 0.0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.buffer = BoundedRingBuffer(capacity: self.capacity)
    }

    var retainedCount: Int { buffer.retainedCount }
    var totalCount: Int { buffer.totalCount }
    var overwrittenCount: Int { buffer.overwrittenCount }
    var chronologicalValues: [Double] { buffer.chronologicalValues }

    mutating func append(_ value: Double) {
        buffer.append(value)
        totalMs += value
    }

    mutating func reset() {
        self = ScrollProfileTimingSamples(capacity: capacity)
    }
}

struct FixedWorkloadCallbackSequencer {
    enum Phase: String, Equatable {
        case warming
        case preMeasurementSettle = "pre_measurement_settle"
        case measurementStart = "measurement_start"
        case measuring
        case postMeasurementSettle = "post_measurement_settle"
        case finished
    }

    enum TickAction: Equatable {
        case warm
        case settleBeforeMeasurement
        case beginMeasurementAndIssueFirstCommand
        case captureResponseAndIssueNextCommand
        case captureFinalResponseAndComplete
        case none
    }

    let targetCommandCount: Int
    private(set) var phase: Phase
    private(set) var issuedCommandCount = 0
    private(set) var measuredCommandResponseCount = 0
    private(set) var preMeasurementSettleCallbackCount = 0
    private(set) var postMeasurementSettleCallbackCount = 0

    init(targetCommandCount: Int, hasWarmup: Bool) {
        self.targetCommandCount = max(1, targetCommandCount)
        phase = hasWarmup ? .warming : .preMeasurementSettle
    }

    mutating func warmupDidComplete() {
        guard phase == .warming else { return }
        phase = .preMeasurementSettle
    }

    mutating func nextTickAction() -> TickAction {
        switch phase {
        case .warming:
            return .warm
        case .preMeasurementSettle:
            preMeasurementSettleCallbackCount += 1
            phase = .measurementStart
            return .settleBeforeMeasurement
        case .measurementStart:
            return .beginMeasurementAndIssueFirstCommand
        case .measuring:
            return .captureResponseAndIssueNextCommand
        case .postMeasurementSettle:
            return .captureFinalResponseAndComplete
        case .finished:
            return .none
        }
    }

    mutating func commandDidIssue() {
        guard phase == .measurementStart || phase == .measuring else { return }
        issuedCommandCount += 1
        phase = issuedCommandCount >= targetCommandCount ? .postMeasurementSettle : .measuring
    }

    mutating func commandResponseDidMeasure(final: Bool) {
        guard phase == .measuring || phase == .postMeasurementSettle else { return }
        measuredCommandResponseCount += 1
        if final {
            postMeasurementSettleCallbackCount += 1
            phase = .finished
        }
    }
}

struct ScrollProfileStructuralMetrics {
    private(set) var counters: [String: Int] = [:]
    private(set) var gauges: [String: Int] = [:]

    mutating func registerCounter(name: String) {
        guard !name.isEmpty, counters[name] == nil else { return }
        counters[name] = 0
    }

    mutating func incrementCounter(name: String, by amount: Int = 1) {
        guard !name.isEmpty, amount > 0 else { return }
        counters[name, default: 0] += amount
    }

    mutating func setGauge(name: String, value: Int) {
        guard !name.isEmpty else { return }
        gauges[name] = value
    }

    mutating func recordMaximumGauge(name: String, value: Int) {
        guard !name.isEmpty else { return }
        gauges[name] = max(gauges[name] ?? value, value)
    }
}

/// Stable JSON-facing description of the actual ordered rows used by a fixed profile workload.
public struct ScrollProfileDatasetMetadata: Equatable, Sendable {
    public let schema: String
    public let datasetID: String
    public let fingerprint: String
    public let itemCount: Int
    public let textItemCount: Int
    public let imageItemCount: Int
    public let pinnedItemCount: Int
    public let uniqueItemIDCount: Int
    public let minimumTextUTF8Bytes: Int
    public let maximumTextUTF8Bytes: Int

    public init(
        schema: String,
        datasetID: String,
        fingerprint: String,
        itemCount: Int,
        textItemCount: Int,
        imageItemCount: Int,
        pinnedItemCount: Int,
        uniqueItemIDCount: Int,
        minimumTextUTF8Bytes: Int,
        maximumTextUTF8Bytes: Int
    ) {
        self.schema = schema
        self.datasetID = datasetID
        self.fingerprint = fingerprint
        self.itemCount = itemCount
        self.textItemCount = textItemCount
        self.imageItemCount = imageItemCount
        self.pinnedItemCount = pinnedItemCount
        self.uniqueItemIDCount = uniqueItemIDCount
        self.minimumTextUTF8Bytes = minimumTextUTF8Bytes
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
    }

    var jsonPayload: [String: Any] {
        [
            "schema": schema,
            "id": datasetID,
            "fingerprint": fingerprint,
            "item_count": itemCount,
            "text_item_count": textItemCount,
            "image_item_count": imageItemCount,
            "pinned_item_count": pinnedItemCount,
            "unique_item_id_count": uniqueItemIDCount,
            "text_utf8_bytes_min": minimumTextUTF8Bytes,
            "text_utf8_bytes_max": maximumTextUTF8Bytes
        ]
    }
}

enum ScrollProfileIngressOverflowDisposition: Sendable {
    case coalesced
    case dropped
}

struct ScrollProfileIngressOverflowStats: Equatable, Sendable {
    var coalescedRecordCount = 0
    var droppedRecordCount = 0
}

struct ScrollProfileIngressDrainBatch<Element: Sendable>: Sendable {
    let elements: [Element]
    let overflow: ScrollProfileIngressOverflowStats
}

/// Lock-serialized, bounded ingress for metrics emitted from arbitrary actors/threads. One
/// scheduled main-actor drain consumes an entire batch, and fixed-workload finalization can
/// synchronously take every retained record that crossed the ingress boundary before completion.
final class ScrollProfileSerializedEventBuffer<Element: Sendable>: @unchecked Sendable {
    typealias OverflowHandler = @Sendable (
        _ pending: inout [Element],
        _ incoming: Element
    ) -> ScrollProfileIngressOverflowDisposition

    private let lock = NSLock()
    private let capacity: Int
    private let overflowHandler: OverflowHandler
    private var pending: [Element] = []
    private var pendingOverflow = ScrollProfileIngressOverflowStats()
    private var drainScheduled = false
    private var isOpen = true

    init(
        capacity: Int = 4_096,
        overflowHandler: @escaping OverflowHandler = { _, _ in .dropped }
    ) {
        self.capacity = max(1, capacity)
        self.overflowHandler = overflowHandler
        pending.reserveCapacity(self.capacity)
    }

    /// Returns `true` only for the empty-to-scheduled transition.
    func enqueue(_ element: Element) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        if pending.count < capacity {
            pending.append(element)
        } else {
            switch overflowHandler(&pending, element) {
            case .coalesced:
                pendingOverflow.coalescedRecordCount += 1
            case .dropped:
                pendingOverflow.droppedRecordCount += 1
            }
            if pending.count > capacity {
                let excessCount = pending.count - capacity
                pending.removeLast(excessCount)
                pendingOverflow.droppedRecordCount += excessCount
            }
        }
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Called repeatedly by the sole scheduled drainer until it returns `nil`.
    func takeNextBatch() -> ScrollProfileIngressDrainBatch<Element>? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            drainScheduled = false
            return nil
        }
        return takePendingLocked()
    }

    /// Synchronous completion barrier. A previously scheduled drainer remains safe: it will see
    /// an empty queue and retire its scheduled flag.
    func closeAndTakePendingForFinalization() -> ScrollProfileIngressDrainBatch<Element> {
        lock.lock()
        defer { lock.unlock() }
        isOpen = false
        return takePendingLocked()
    }

    func reopenDiscardingPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        pendingOverflow = ScrollProfileIngressOverflowStats()
        drainScheduled = false
        isOpen = true
        lock.unlock()
    }

    private func takePendingLocked() -> ScrollProfileIngressDrainBatch<Element> {
        let batch = ScrollProfileIngressDrainBatch(
            elements: pending,
            overflow: pendingOverflow
        )
        pending.removeAll(keepingCapacity: true)
        pendingOverflow = ScrollProfileIngressOverflowStats()
        return batch
    }
}

final class ScrollProfileMeasurementEpoch: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let generation: UInt64
        let measurementStart: TimeInterval?
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var measurementStart: TimeInterval?

    func begin(at timestamp: TimeInterval) -> Snapshot {
        lock.lock()
        generation &+= 1
        measurementStart = timestamp
        let snapshot = Snapshot(generation: generation, measurementStart: timestamp)
        lock.unlock()
        return snapshot
    }

    /// Serializes the generation change with an external ingress transition. Producers use
    /// `withSnapshot` while enqueueing, so none can observe the new generation until `body` has
    /// reopened the matching queue.
    func begin<T>(
        at timestamp: TimeInterval,
        whileLocked body: () -> T
    ) -> (snapshot: Snapshot, value: T) {
        lock.lock()
        generation &+= 1
        measurementStart = timestamp
        let snapshot = Snapshot(generation: generation, measurementStart: timestamp)
        let value = body()
        lock.unlock()
        return (snapshot, value)
    }

    func close(generation expectedGeneration: UInt64) {
        lock.lock()
        if generation == expectedGeneration {
            measurementStart = nil
        }
        lock.unlock()
    }

    /// Serializes the queue's final drain/close with the epoch close. An enqueue either completes
    /// before `body` drains it, or observes the closed epoch after this method returns.
    func close<T>(
        generation expectedGeneration: UInt64,
        whileLocked body: () -> T
    ) -> T {
        lock.lock()
        let value = body()
        if generation == expectedGeneration {
            measurementStart = nil
        }
        lock.unlock()
        return value
    }

    func withSnapshot<T>(_ body: (Snapshot) -> T) -> T {
        lock.lock()
        let value = body(
            Snapshot(generation: generation, measurementStart: measurementStart)
        )
        lock.unlock()
        return value
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(generation: generation, measurementStart: measurementStart)
        lock.unlock()
        return snapshot
    }
}

// MARK: - Scroll Performance Profiling (Debug/UITest)

@MainActor
public final class ScrollPerformanceProfile {
    private struct Config {
        let enabled: Bool
        let durationSeconds: TimeInterval
        let minSamples: Int
        let outputPath: String
        let animationCallbackThresholdMultiplier: Double
        let expectedAnimationCallbackIntervalMs: Double?
        let maxSamples: Int
        let autoScrollEnabled: Bool
        let autoScrollStepPx: Double
        let autoScrollIntervalSeconds: TimeInterval
        let fixedCommandCount: Int?
        let warmRoundCount: Int
        let startNotificationName: String?

        static func load() -> Config {
            let env = ProcessInfo.processInfo.environment
            let enabled = parseBool(env["SCOPY_SCROLL_PROFILE"]) ?? false
            let durationSeconds = parseDouble(env["SCOPY_PROFILE_DURATION_SEC"]) ?? 6.0
            let minSamples = max(30, parseInt(env["SCOPY_PROFILE_MIN_SAMPLES"]) ?? 180)
            let outputPath = env["SCOPY_PROFILE_OUTPUT"] ?? "/tmp/scopy_scroll_profile.json"
            let animationCallbackThresholdMultiplier =
                parseDouble(env["SCOPY_PROFILE_CALLBACK_THRESHOLD_MULTIPLIER"])
                ?? parseDouble(env["SCOPY_PROFILE_DROP_THRESHOLD"])
                ?? 1.5
            let expectedAnimationCallbackIntervalMs =
                parseDouble(env["SCOPY_PROFILE_EXPECTED_CALLBACK_INTERVAL_MS"])
                ?? parseDouble(env["SCOPY_PROFILE_EXPECTED_FRAME_MS"])
            let maxSamples = max(500, parseInt(env["SCOPY_PROFILE_MAX_SAMPLES"]) ?? 2000)
            let fixedCommandCount = parseInt(env["SCOPY_PROFILE_FIXED_COMMAND_COUNT"])
                .flatMap { $0 > 0 ? $0 : nil }
            let autoScrollEnabled = fixedCommandCount != nil ||
                (parseBool(env["SCOPY_PROFILE_AUTO_SCROLL"]) ?? false)
            let autoScrollStepPx = parseDouble(env["SCOPY_PROFILE_AUTO_SCROLL_STEP_PX"]) ?? 36.0
            let autoScrollIntervalSeconds = parseDouble(env["SCOPY_PROFILE_AUTO_SCROLL_INTERVAL_SEC"]) ?? (1.0 / 60.0)
            let warmRoundCount = max(0, parseInt(env["SCOPY_PROFILE_WARM_ROUNDS"]) ?? 2)
            let startNotificationName = normalized(env["SCOPY_PROFILE_START_NOTIFICATION"])

            return Config(
                enabled: enabled,
                durationSeconds: durationSeconds,
                minSamples: minSamples,
                outputPath: outputPath,
                animationCallbackThresholdMultiplier: animationCallbackThresholdMultiplier,
                expectedAnimationCallbackIntervalMs: expectedAnimationCallbackIntervalMs,
                maxSamples: maxSamples,
                autoScrollEnabled: autoScrollEnabled,
                autoScrollStepPx: autoScrollStepPx,
                autoScrollIntervalSeconds: autoScrollIntervalSeconds,
                fixedCommandCount: fixedCommandCount,
                warmRoundCount: warmRoundCount,
                startNotificationName: startNotificationName
            )
        }

        private static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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

    enum MetricName {
        static let animationCallbackInterval = "animation_callback_interval_ms"
        static let expectedAnimationCallbackInterval = "expected_animation_callback_interval_ms"
        static let animationCallbackOverThresholdRatio = "animation_callback_over_threshold_ratio"
        static let activeAnimationCallbackInterval = "active_animation_callback_interval_ms"
        static let activeAnimationCallbackOverThresholdRatio = "active_animation_callback_over_threshold_ratio"
        static let longAnimationCallbackAttribution = "long_animation_callback_attribution"
        static let mainThreadLongAnimationCallbackAttribution = "main_thread_long_animation_callback_attribution"
    }

    static let fixedWorkloadRequiredCounterNames = [
        "interaction.session_init",
        "interaction.observer_install",
        "interaction.idle_disappear_fast_path",
        "row.descriptor_cache_hit",
        "row.descriptor_cache_miss",
        "row.relative_time_cache_hit",
        "row.relative_time_cache_miss",
        "list.load_more_attempt",
        "list.pagination_request",
        "row.markdown_menu_signal_cache_hit",
        "row.markdown_menu_signal_cache_miss",
        "row.markdown_menu_signal_uncached",
        "profile.ingress_coalesced",
        "profile.ingress_dropped"
    ]

    private static let activeSlotCurrentGauge = "active_slot_current"
    private static let activeSlotMaximumGauge = "active_slot_max"
    private static let suppressedCandidateCurrentGauge = "suppressed_candidate_current"
    private static let suppressedCandidateMaximumGauge = "suppressed_candidate_max"

    static var buildConfiguration: String {
#if DEBUG
        "Debug"
#else
        "Release"
#endif
    }

    static func executableFingerprint(
        at executableURL: URL? = Bundle.main.executableURL
    ) -> String {
        guard let executableURL,
              let data = try? Data(contentsOf: executableURL, options: .mappedIfSafe) else {
            return ""
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

    private static func currentExecutableFingerprint() -> String {
        executableFingerprint()
    }

    struct TimingEvent: Sendable {
        let name: String
        let start: TimeInterval
        let end: TimeInterval
        let durationMs: Double

        init(name: String, elapsedMs: Double, endedAt: TimeInterval) {
            let clampedElapsedMs = elapsedMs.isFinite ? max(0, elapsedMs) : 0
            self.name = name
            self.start = endedAt - clampedElapsedMs / 1000
            self.end = endedAt
            self.durationMs = clampedElapsedMs
        }

        init(name: String, start: TimeInterval, end: TimeInterval, durationMs: Double) {
            self.name = name
            self.start = start
            self.end = end
            self.durationMs = durationMs
        }
    }

    private enum QueuedRecordPayload: Sendable {
        case timing(TimingEvent)
        case incrementCounter(name: String, amount: Int)
        case setGauge(name: String, value: Int)
    }

    private struct QueuedRecord: Sendable {
        let generation: UInt64
        let recordedAt: TimeInterval
        let payload: QueuedRecordPayload
    }

    typealias MetricEvent = TimingEvent

    struct AnimationCallbackSample: Sendable {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
        let intervalMs: Double
        let offsetDelta: Double?
        let scrollSpeed: Double?
        let isScrolling: Bool

        init(
            index: Int,
            start: TimeInterval,
            end: TimeInterval,
            intervalMs: Double,
            offsetDelta: Double?,
            scrollSpeed: Double?,
            isScrolling: Bool
        ) {
            self.index = index
            self.start = start
            self.end = end
            self.intervalMs = intervalMs
            self.offsetDelta = offsetDelta
            self.scrollSpeed = scrollSpeed
            self.isScrolling = isScrolling
        }
    }

    typealias FrameSample = AnimationCallbackSample

    private struct MetricAggregate {
        var count = 0
        var totalMs = 0.0
        var overlapMs = 0.0
        var maxMs = 0.0
        var callbackIndexes: Set<Int> = []

        mutating func add(event: TimingEvent, overlapMs: Double, callbackIndex: Int) {
            count += 1
            totalMs += event.durationMs
            self.overlapMs += overlapMs
            maxMs = max(maxMs, event.durationMs)
            callbackIndexes.insert(callbackIndex)
        }

        var payload: [String: Any] {
            [
                "count": count,
                "callback_count": callbackIndexes.count,
                "total_ms": totalMs,
                "overlap_ms": overlapMs,
                "max_ms": maxMs
            ]
        }
    }

    @MainActor
    private final class FixedDisplayLinkDriver: NSObject {
        weak var owner: ScrollPerformanceProfile?
        weak var scrollView: NSScrollView?
        private let step: CGFloat
        private let warmRounds: Int
        private var sequencer: FixedWorkloadCallbackSequencer
        private var warmDirection: CGFloat = 1
        private var measurementDirection: CGFloat = 1
        private var completedWarmRounds = 0
        private var displayLink: CADisplayLink?

        init(
            owner: ScrollPerformanceProfile,
            scrollView: NSScrollView,
            targetCommands: Int,
            step: CGFloat,
            warmRounds: Int
        ) {
            self.owner = owner
            self.scrollView = scrollView
            self.step = max(1, step)
            self.warmRounds = warmRounds
            self.sequencer = FixedWorkloadCallbackSequencer(
                targetCommandCount: targetCommands,
                hasWarmup: warmRounds > 0
            )
        }

        func start() {
            guard displayLink == nil, let scrollView else { return }
            // A view-bound display link can suspend when its window is occluded between UI-test
            // launches. The fixed workload needs a refresh-clock source independent of pointer,
            // key-window, and occlusion state; the actual scroll target remains the production
            // List's NSScrollView.
            let link = (scrollView.window?.screen ?? NSScreen.main)?.displayLink(
                target: self,
                selector: #selector(displayLinkTick(_:))
            ) ?? scrollView.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func invalidate() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func displayLinkTick(_ displayLink: CADisplayLink) {
            guard let scrollView, let owner else {
                invalidate()
                return
            }
            let callbackDate = Date()
            switch sequencer.nextTickAction() {
            case .warm:
                advanceWarmRound(scrollView)
            case .settleBeforeMeasurement:
                break
            case .beginMeasurementAndIssueFirstCommand:
                beginMeasurement(scrollView, owner: owner, callbackDate: callbackDate)
                if issueMeasurementCommand(scrollView, owner: owner) {
                    sequencer.commandDidIssue()
                }
            case .captureResponseAndIssueNextCommand:
                owner.recordAnimationCallback(callbackDate)
                sequencer.commandResponseDidMeasure(final: false)
                if issueMeasurementCommand(scrollView, owner: owner) {
                    sequencer.commandDidIssue()
                }
            case .captureFinalResponseAndComplete:
                owner.recordAnimationCallback(callbackDate)
                sequencer.commandResponseDidMeasure(final: true)
                displayLink.invalidate()
                self.displayLink = nil
                owner.fixedWorkloadDidComplete(sequencer: sequencer)
            case .none:
                break
            }
        }

        private func advanceWarmRound(_ scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            guard maxY > 0 else { return }

            let currentY = clipView.bounds.origin.y
            let nextY = min(max(0, currentY + warmDirection * step), maxY)
            scroll(clipView: clipView, scrollView: scrollView, to: nextY)

            if warmDirection > 0, nextY >= maxY {
                warmDirection = -1
            } else if warmDirection < 0, nextY <= 0 {
                completedWarmRounds += 1
                if completedWarmRounds >= warmRounds {
                    sequencer.warmupDidComplete()
                } else {
                    warmDirection = 1
                }
            }
        }

        private func beginMeasurement(
            _ scrollView: NSScrollView,
            owner: ScrollPerformanceProfile,
            callbackDate: Date
        ) {
            let clipView = scrollView.contentView
            scroll(clipView: clipView, scrollView: scrollView, to: 0)
            measurementDirection = 1
            owner.fixedWorkloadDidBegin(
                warmRounds: completedWarmRounds,
                screenMaximumFramesPerSecond: scrollView.window?.screen?.maximumFramesPerSecond
                    ?? NSScreen.main?.maximumFramesPerSecond
                    ?? 0,
                at: callbackDate.timeIntervalSinceReferenceDate
            )
            // Seed the callback clock before command 1. The next display-link callback is thus
            // response 1, rather than a warmup-tail interval.
            owner.recordAnimationCallback(callbackDate)
        }

        @discardableResult
        private func issueMeasurementCommand(
            _ scrollView: NSScrollView,
            owner: ScrollPerformanceProfile
        ) -> Bool {
            guard let documentView = scrollView.documentView else { return false }
            let clipView = scrollView.contentView
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            guard maxY > 0 else { return false }

            let currentY = clipView.bounds.origin.y
            var nextY = currentY + measurementDirection * step
            if nextY >= maxY {
                nextY = maxY
                measurementDirection = -1
            } else if nextY <= 0 {
                nextY = 0
                measurementDirection = 1
            }
            scroll(clipView: clipView, scrollView: scrollView, to: nextY)
            owner.fixedWorkloadCommandDidExecute(observedDelta: abs(nextY - currentY))
            return true
        }

        private func scroll(
            clipView: NSClipView,
            scrollView: NSScrollView,
            to y: CGFloat
        ) {
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clipView)
        }

    }

    public static let shared = ScrollPerformanceProfile()
    public nonisolated static let isEnabled: Bool = Config.load().enabled
    private nonisolated static let measurementEpoch = ScrollProfileMeasurementEpoch()
    private nonisolated static let queuedRecords =
        ScrollProfileSerializedEventBuffer<QueuedRecord>(
            capacity: 8_192,
            overflowHandler: { pending, incoming in
                resolveQueuedRecordOverflow(pending: &pending, incoming: incoming)
            }
        )

    public var usesFixedDriverAnimationSampler: Bool {
        config.fixedCommandCount != nil
    }

    public func prepareForLaunch() {
        guard config.enabled, config.startNotificationName != nil else { return }
        installStartNotificationObserverIfNeeded()
    }

    private let config: Config
    private weak var scrollView: NSScrollView?

    private var isScrolling = false
    private var startTimestamp: TimeInterval?
    private var lastAnimationCallbackTimestamp: TimeInterval?
    private var lastScrollOffset: CGFloat?
    private var expectedAnimationCallbackIntervalMs: Double?
    private var hasWritten = false
    private var autoScrollTimer: Timer?
    private var fixedDisplayLinkDriver: FixedDisplayLinkDriver?
    private var autoScrollDirection: CGFloat = 1
    private var fixedWorkloadCommandCount = 0
    private var fixedWorkloadObservedPathPx = 0.0
    private var fixedWorkloadCompleted = false
    private var fixedWorkloadWarmRounds = 0
    private var screenMaximumFramesPerSecond = 0
    private var workloadLoadedCount = 0
    private var workloadTotalCount = 0
    private var workloadCanLoadMore = false
    private var workloadDatasetMetadata: ScrollProfileDatasetMetadata?
    private var latestActiveSlotCount = 0
    private var latestSuppressedCandidateCount = 0
    private var isStartNotificationObserverInstalled = false
    private var didReceiveStartNotification = false
    private var mainRunLoopObserver: CFRunLoopObserver?
    private var mainRunLoopActiveStart: TimeInterval?

    private var animationCallbackIntervalsMs: BoundedRingBuffer<Double>
    private var animationCallbackIntervalTotalMs = 0.0
    private var scrollSpeedSamples: BoundedRingBuffer<Double>
    private var timingBuckets: [String: ScrollProfileTimingSamples] = [:]
    private var timingEvents: BoundedRingBuffer<TimingEvent>
    private var animationCallbackSamples: BoundedRingBuffer<AnimationCallbackSample>
    private var mainRunLoopActiveDurationsMs: ScrollProfileTimingSamples
    private var mainRunLoopEvents: BoundedRingBuffer<TimingEvent>
    private var structuralMetrics = ScrollProfileStructuralMetrics()
    private var animationCallbackSequence = 0
    private var measurementGeneration: UInt64 = 0
    private var fixedWorkloadMeasuredCommandResponseCount = 0
    private var fixedWorkloadPreMeasurementSettleCallbackCount = 0
    private var fixedWorkloadPostMeasurementSettleCallbackCount = 0
    private var fixedWorkloadFinalizationState = "not_started"

    private init() {
        let config = Config.load()
        self.config = config
        self.expectedAnimationCallbackIntervalMs = config.expectedAnimationCallbackIntervalMs
        self.animationCallbackIntervalsMs = BoundedRingBuffer(capacity: config.maxSamples)
        self.scrollSpeedSamples = BoundedRingBuffer(capacity: config.maxSamples)
        self.timingEvents = BoundedRingBuffer(capacity: config.maxSamples)
        self.animationCallbackSamples = BoundedRingBuffer(capacity: config.maxSamples)
        self.mainRunLoopActiveDurationsMs = ScrollProfileTimingSamples(capacity: config.maxSamples)
        self.mainRunLoopEvents = BoundedRingBuffer(capacity: config.maxSamples)
    }

    public func attachScrollView(_ scrollView: NSScrollView) {
        guard config.enabled else { return }
        if config.fixedCommandCount != nil {
            guard scrollView.documentView is NSTableView
                || scrollView.documentView is NSOutlineView else { return }
        }
        let attachmentChanged = self.scrollView !== scrollView
        if attachmentChanged, let fixedDisplayLinkDriver {
            // SwiftUI can replace a provisional scroll view while the List materializes. A
            // display-link driver owns only a weak view reference; leaving its invalidated object
            // in this slot prevents the real list attachment from starting a new fixed workload.
            fixedDisplayLinkDriver.invalidate()
            self.fixedDisplayLinkDriver = nil
        }
        self.scrollView = scrollView
        if config.startNotificationName != nil, !didReceiveStartNotification {
            installStartNotificationObserverIfNeeded()
            return
        }
        startAutoScrollIfNeeded(scrollView)
    }

    public func setListWorkloadMetadata(
        loadedCount: Int,
        totalCount: Int,
        canLoadMore: Bool,
        dataset: ScrollProfileDatasetMetadata? = nil
    ) {
        guard config.enabled else { return }
        workloadLoadedCount = max(0, loadedCount)
        workloadTotalCount = max(0, totalCount)
        workloadCanLoadMore = canLoadMore
        workloadDatasetMetadata = dataset
    }

    /// Publishes both the latest coordinator ownership and the maximum observed during the active
    /// measurement. Keeping the latest snapshot before measurement lets the fixed-workload reset
    /// seed explicit values instead of treating missing instrumentation as zero.
    public func recordPassivePathSnapshot(
        activeSlotCount: Int,
        suppressedCandidateCount: Int
    ) {
        guard config.enabled else { return }
        latestActiveSlotCount = max(0, activeSlotCount)
        latestSuppressedCandidateCount = max(0, suppressedCandidateCount)
        if config.fixedCommandCount != nil {
            guard startTimestamp != nil, !fixedWorkloadCompleted else { return }
        }
        publishPassivePathGauges()
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

    public func recordAnimationCallback(_ date: Date) {
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

        if let lastAnimationCallbackTimestamp {
            let intervalMs = (now - lastAnimationCallbackTimestamp) * 1000
            animationCallbackIntervalsMs.append(intervalMs)
            animationCallbackIntervalTotalMs += intervalMs
            updateExpectedAnimationCallbackIntervalIfNeeded()

            if let delta = offsetDelta, intervalMs > 0 {
                let speed = delta / (intervalMs / 1000)
                scrollSpeedSamples.append(speed)
            }

            let speed: Double? = {
                guard let delta = offsetDelta, intervalMs > 0 else { return nil }
                return delta / (intervalMs / 1000)
            }()
            animationCallbackSamples.append(
                AnimationCallbackSample(
                    index: animationCallbackSequence,
                    start: lastAnimationCallbackTimestamp,
                    end: now,
                    intervalMs: intervalMs,
                    offsetDelta: offsetDelta,
                    scrollSpeed: speed,
                    isScrolling: isScrolling
                )
            )
            animationCallbackSequence += 1
        }

        lastAnimationCallbackTimestamp = now
        lastScrollOffset = currentOffset
        maybeFinalize(now: now)
    }

    public func recordFrameTick(_ date: Date) {
        recordAnimationCallback(date)
    }

    public func recordTiming(name: String, elapsedMs: Double) {
        let event = TimingEvent(
            name: name,
            elapsedMs: elapsedMs,
            endedAt: Date().timeIntervalSinceReferenceDate
        )
        recordTiming(event)
    }

    public func recordMetric(name: String, elapsedMs: Double) {
        recordTiming(name: name, elapsedMs: elapsedMs)
    }

    private func recordTiming(_ event: TimingEvent) {
        guard config.enabled else { return }
        if config.fixedCommandCount != nil {
            guard let startTimestamp,
                  Self.timingEventBelongsToFixedMeasurement(
                    event,
                    startingAt: startTimestamp,
                    measurementCompleted: fixedWorkloadCompleted
                  ) else {
                return
            }
        }
        timingBuckets[
            event.name,
            default: ScrollProfileTimingSamples(capacity: config.maxSamples)
        ].append(event.durationMs)
        timingEvents.append(event)
    }

    static func timingEventBelongsToFixedMeasurement(
        _ event: TimingEvent,
        startingAt startTimestamp: TimeInterval,
        measurementCompleted: Bool
    ) -> Bool {
        !measurementCompleted
            && event.start >= startTimestamp
            && event.end >= startTimestamp
    }

    public nonisolated static func recordTiming(name: String, elapsedMs: Double) {
        guard isEnabled else { return }
        let event = TimingEvent(
            name: name,
            elapsedMs: elapsedMs,
            endedAt: Date().timeIntervalSinceReferenceDate
        )
        enqueue(.timing(event))
    }

    public nonisolated static func recordMetric(name: String, elapsedMs: Double) {
        recordTiming(name: name, elapsedMs: elapsedMs)
    }

    public func incrementCounter(name: String, by amount: Int = 1) {
        guard config.enabled else { return }
        if config.fixedCommandCount != nil {
            guard startTimestamp != nil, !fixedWorkloadCompleted else { return }
        }
        structuralMetrics.incrementCounter(name: name, by: amount)
    }

    public nonisolated static func incrementCounter(name: String, by amount: Int = 1) {
        guard isEnabled, !name.isEmpty, amount > 0 else { return }
        enqueue(.incrementCounter(name: name, amount: amount))
    }

    public func setGauge(name: String, value: Int) {
        guard config.enabled else { return }
        if config.fixedCommandCount != nil {
            guard startTimestamp != nil, !fixedWorkloadCompleted else { return }
        }
        structuralMetrics.setGauge(name: name, value: value)
    }

    public nonisolated static func setGauge(name: String, value: Int) {
        guard isEnabled, !name.isEmpty else { return }
        enqueue(.setGauge(name: name, value: value))
    }

    private nonisolated static func resolveQueuedRecordOverflow(
        pending: inout [QueuedRecord],
        incoming: QueuedRecord
    ) -> ScrollProfileIngressOverflowDisposition {
        switch incoming.payload {
        case .incrementCounter(let name, let amount):
            if let index = pending.lastIndex(where: { record in
                guard record.generation == incoming.generation,
                      case .incrementCounter(let existingName, _) = record.payload else {
                    return false
                }
                return existingName == name
            }), case .incrementCounter(_, let existingAmount) = pending[index].payload {
                pending[index] = QueuedRecord(
                    generation: incoming.generation,
                    recordedAt: incoming.recordedAt,
                    payload: .incrementCounter(name: name, amount: existingAmount + amount)
                )
                return .coalesced
            }
        case .setGauge(let name, let value):
            if let index = pending.lastIndex(where: { record in
                guard record.generation == incoming.generation,
                      case .setGauge(let existingName, _) = record.payload else {
                    return false
                }
                return existingName == name
            }) {
                pending[index] = QueuedRecord(
                    generation: incoming.generation,
                    recordedAt: incoming.recordedAt,
                    payload: .setGauge(name: name, value: value)
                )
                return .coalesced
            }
        case .timing:
            break
        }

        // The destination timing buffers are themselves bounded and retain newest samples. Under
        // sustained pressure, replace the oldest queued timing sample so counter totals and the
        // eventual newest-sample timing semantics remain intact. The drop is reported explicitly.
        if let timingIndex = pending.firstIndex(where: { record in
            guard case .timing = record.payload else { return false }
            return true
        }) {
            pending.remove(at: timingIndex)
            pending.append(incoming)
        }
        return .dropped
    }

    private nonisolated static func enqueue(_ payload: QueuedRecordPayload) {
        let recordedAt = Date().timeIntervalSinceReferenceDate
        let shouldScheduleDrain = measurementEpoch.withSnapshot { epoch in
            queuedRecords.enqueue(
                QueuedRecord(
                    generation: epoch.generation,
                    recordedAt: recordedAt,
                    payload: payload
                )
            )
        }
        guard shouldScheduleDrain else { return }
        Task { @MainActor in
            shared.drainQueuedRecords()
        }
    }

    private func drainQueuedRecords() {
        while let batch = Self.queuedRecords.takeNextBatch() {
            applyQueuedRecords(batch.elements)
            applyIngressOverflowStats(batch.overflow)
        }
    }

    private func closeMeasurementIngressAndDrainQueuedRecords() {
        let batch = Self.measurementEpoch.close(
            generation: measurementGeneration,
            whileLocked: {
                Self.queuedRecords.closeAndTakePendingForFinalization()
            }
        )
        applyQueuedRecords(batch.elements)
        applyIngressOverflowStats(batch.overflow)
    }

    private func applyIngressOverflowStats(_ stats: ScrollProfileIngressOverflowStats) {
        incrementCounter(name: "profile.ingress_coalesced", by: stats.coalescedRecordCount)
        incrementCounter(name: "profile.ingress_dropped", by: stats.droppedRecordCount)
    }

    private func applyQueuedRecords(_ records: [QueuedRecord]) {
        for record in records {
            if config.fixedCommandCount != nil {
                guard record.generation == measurementGeneration,
                      let startTimestamp,
                      record.recordedAt >= startTimestamp else {
                    continue
                }
            }
            switch record.payload {
            case .timing(let event):
                recordTiming(event)
            case .incrementCounter(let name, let amount):
                incrementCounter(name: name, by: amount)
            case .setGauge(let name, let value):
                setGauge(name: name, value: value)
            }
        }
    }

    private func updateExpectedAnimationCallbackIntervalIfNeeded() {
        guard expectedAnimationCallbackIntervalMs == nil else { return }
        let values = animationCallbackIntervalsMs.chronologicalValues
        let warmupCount = min(30, values.count)
        guard warmupCount >= 12 else { return }
        let sample = Array(values.prefix(warmupCount)).sorted()
        expectedAnimationCallbackIntervalMs = Self.percentile(sample, p: 50)
    }

    private func maybeFinalize(now: TimeInterval) {
        guard !hasWritten else { return }
        guard let startTimestamp else { return }
        let elapsed = now - startTimestamp
        if let fixedCommandCount = config.fixedCommandCount {
            guard fixedWorkloadCompleted,
                  fixedWorkloadCommandCount == fixedCommandCount else { return }
        } else {
            guard elapsed >= config.durationSeconds else { return }
        }
        guard animationCallbackIntervalsMs.count >= config.minSamples else { return }
        writeReport(elapsedSeconds: elapsed)
    }

    private func writeReport(elapsedSeconds: TimeInterval) {
        hasWritten = true
        stopAutoScrollIfNeeded()
        stopMainRunLoopObserverIfNeeded(at: Date().timeIntervalSinceReferenceDate)
        let callbackIntervalsMs = animationCallbackIntervalsMs.chronologicalValues
        let callbackSamples = animationCallbackSamples.chronologicalValues
        let retainedTimingEvents = timingEvents.chronologicalValues
        let retainedMainRunLoopEvents = mainRunLoopEvents.chronologicalValues
        let expectedCallbackIntervalMs = expectedAnimationCallbackIntervalMs ?? 0
        var callbackMetrics = Self.buildAnimationCallbackMetricPayload(
            intervalsMs: callbackIntervalsMs,
            samples: callbackSamples,
            expectedIntervalMs: expectedCallbackIntervalMs,
            thresholdMultiplier: config.animationCallbackThresholdMultiplier
        )
        Self.applyRetentionMetadata(
            to: &callbackMetrics,
            metricName: MetricName.animationCallbackInterval,
            retainedCount: animationCallbackIntervalsMs.retainedCount,
            totalCount: animationCallbackIntervalsMs.totalCount,
            overwrittenCount: animationCallbackIntervalsMs.overwrittenCount,
            totalMs: animationCallbackIntervalTotalMs
        )
        // Deprecated alias carries the same retention contract as the canonical metric.
        Self.applyRetentionMetadata(
            to: &callbackMetrics,
            metricName: "frame_ms",
            retainedCount: animationCallbackIntervalsMs.retainedCount,
            totalCount: animationCallbackIntervalsMs.totalCount,
            overwrittenCount: animationCallbackIntervalsMs.overwrittenCount,
            totalMs: animationCallbackIntervalTotalMs
        )
        if animationCallbackSamples.overwrittenCount > 0 {
            Self.removePercentile95(
                from: &callbackMetrics,
                metricNames: [MetricName.activeAnimationCallbackInterval, "active_frame_ms"]
            )
        }
        let speedStats = Self.computeStats(scrollSpeedSamples.chronologicalValues)
        let mainRunLoopStats = Self.computeStats(mainRunLoopActiveDurationsMs.chronologicalValues)

        var bucketStats: [String: [String: Any]] = [:]
        for (key, bucket) in timingBuckets {
            let stats = Self.computeStats(bucket.chronologicalValues)
            let totalMs = bucket.totalMs
            var payload: [String: Any] = [
                "count": bucket.totalCount,
                "retained_count": bucket.retainedCount,
                "total_count": bucket.totalCount,
                "overwritten_count": bucket.overwrittenCount,
                "total_ms": totalMs,
                "avg": bucket.totalCount > 0 ? totalMs / Double(bucket.totalCount) : 0
            ]
            if bucket.overwrittenCount == 0 {
                payload["p50"] = stats.p50
                payload["p95"] = stats.p95
            }
            bucketStats[key] = payload
        }

        let env = ProcessInfo.processInfo.environment
        let longAnimationCallbackAttribution = Self.buildLongAnimationCallbackAttribution(
            callbackSamples: callbackSamples,
            timingEvents: retainedTimingEvents,
            expectedCallbackIntervalMs: expectedCallbackIntervalMs,
            thresholdMultiplier: config.animationCallbackThresholdMultiplier,
            maxCallbackDetails: 12,
            timelineStart: startTimestamp
        )
        let mainThreadLongAnimationCallbackAttribution = Self.buildLongAnimationCallbackAttribution(
            callbackSamples: callbackSamples,
            timingEvents: retainedMainRunLoopEvents,
            expectedCallbackIntervalMs: expectedCallbackIntervalMs,
            thresholdMultiplier: config.animationCallbackThresholdMultiplier,
            maxCallbackDetails: 12,
            timelineStart: startTimestamp
        )
        let legacyLongFrameAttribution = Self.legacyLongFrameAttribution(
            from: longAnimationCallbackAttribution
        )
        let legacyMainThreadLongFrameAttribution = Self.legacyLongFrameAttribution(
            from: mainThreadLongAnimationCallbackAttribution
        )
        let accessibilityTree = buildAccessibilitySnapshot()
        let activeCallbackCount = callbackSamples.filter(Self.isActiveAnimationCallback).count
        let movingCallbackCount = callbackSamples.filter { ($0.offsetDelta ?? 0) > 0 }.count
        let liveScrollCallbackCount = callbackSamples.filter(\.isScrolling).count
        let speedPayload: [String: Any] = [
            "count": speedStats.count,
            "min": speedStats.min,
            "avg": speedStats.avg,
            "p50": speedStats.p50,
            "p95": speedStats.p95,
            "max": speedStats.max
        ]
        var mainRunLoopPayload: [String: Any] = [
            "count": mainRunLoopActiveDurationsMs.totalCount,
            "retained_count": mainRunLoopActiveDurationsMs.retainedCount,
            "total_count": mainRunLoopActiveDurationsMs.totalCount,
            "overwritten_count": mainRunLoopActiveDurationsMs.overwrittenCount,
            "total_ms": mainRunLoopActiveDurationsMs.totalMs,
            "avg": mainRunLoopActiveDurationsMs.totalCount > 0
                ? mainRunLoopActiveDurationsMs.totalMs / Double(mainRunLoopActiveDurationsMs.totalCount)
                : 0
        ]
        if mainRunLoopActiveDurationsMs.overwrittenCount == 0 {
            mainRunLoopPayload["min"] = mainRunLoopStats.min
            mainRunLoopPayload["p50"] = mainRunLoopStats.p50
            mainRunLoopPayload["p95"] = mainRunLoopStats.p95
            mainRunLoopPayload["max"] = mainRunLoopStats.max
        }
        let structuralPayload: [String: Any] = [
            "counters": structuralMetrics.counters,
            "gauges": structuralMetrics.gauges
        ]
        let sampleHealthPayload: [String: Any] = [
            "scroll_view_attached": scrollView != nil,
            "animation_callback_count": animationCallbackSamples.totalCount,
            "animation_callback_retained_count": animationCallbackSamples.retainedCount,
            "animation_callback_total_count": animationCallbackSamples.totalCount,
            "animation_callback_overwritten_count": animationCallbackSamples.overwrittenCount,
            "active_animation_callback_count": activeCallbackCount,
            "moving_animation_callback_count": movingCallbackCount,
            "live_scroll_animation_callback_count": liveScrollCallbackCount,
            // Deprecated compatibility aliases retained for existing report consumers.
            "frame_count": animationCallbackSamples.totalCount,
            "active_frame_count": activeCallbackCount,
            "moving_frame_count": movingCallbackCount,
            "live_scroll_frame_count": liveScrollCallbackCount
        ]
        let configPayload: [String: Any] = [
            "mock_dataset_id": env["SCOPY_MOCK_DATASET_ID"] ?? "",
            "mock_item_count": env["SCOPY_MOCK_ITEM_COUNT"] ?? "",
            "mock_image_count": env["SCOPY_MOCK_IMAGE_COUNT"] ?? "",
            "mock_text_length": env["SCOPY_MOCK_TEXT_LENGTH"] ?? "",
            "mock_show_thumbnails": env["SCOPY_MOCK_SHOW_THUMBNAILS"] ?? "",
            "profile_accessibility": env["SCOPY_PROFILE_ACCESSIBILITY"] ?? "",
            "profile_auto_scroll": env["SCOPY_PROFILE_AUTO_SCROLL"] ?? "",
            "passive_row": env["SCOPY_PERF_PASSIVE_ROW"] ?? "",
            "markdown_menu_signal_cache": env["SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE"] ?? "",
            "SCOPY_PERF_HISTORY_INDEX": env["SCOPY_PERF_HISTORY_INDEX"] ?? "",
            "SCOPY_PERF_SCROLL_RESOLVER_CACHE": env["SCOPY_PERF_SCROLL_RESOLVER_CACHE"] ?? "",
            "SCOPY_PERF_MARKDOWN_RESOLVER_CACHE": env["SCOPY_PERF_MARKDOWN_RESOLVER_CACHE"] ?? "",
            "SCOPY_PERF_PREVIEW_TASK_BUDGET": env["SCOPY_PERF_PREVIEW_TASK_BUDGET"] ?? "",
            "SCOPY_PERF_SHORT_QUERY_DEBOUNCE": env["SCOPY_PERF_SHORT_QUERY_DEBOUNCE"] ?? "",
            "source_fingerprint": env["SCOPY_PROFILE_SOURCE_FINGERPRINT"] ?? "",
            "executable_fingerprint": Self.currentExecutableFingerprint(),
            "runner_executable_fingerprint": env["SCOPY_PROFILE_EXECUTABLE_FINGERPRINT"] ?? "",
            "build_configuration": Self.buildConfiguration,
            "fixed_command_count": config.fixedCommandCount ?? 0,
            "max_samples": config.maxSamples,
            "animation_callback_source": config.fixedCommandCount == nil
                ? "TimelineView(.animation)"
                : "NSScreen CADisplayLink",
            "auto_scroll_step_px": config.autoScrollStepPx,
            "warm_round_count": config.warmRoundCount
        ]
        var fixedWorkloadPayload: [String: Any] = [
            "enabled": config.fixedCommandCount != nil,
            "command_target": config.fixedCommandCount ?? 0,
            "command_count": fixedWorkloadCommandCount,
            "issued_command_count": fixedWorkloadCommandCount,
            "measured_command_response_count": fixedWorkloadMeasuredCommandResponseCount,
            "pre_measurement_settle_callback_count": fixedWorkloadPreMeasurementSettleCallbackCount,
            "post_measurement_settle_callback_count": fixedWorkloadPostMeasurementSettleCallbackCount,
            "finalization_state": fixedWorkloadFinalizationState,
            "measurement_generation": Int(measurementGeneration),
            "step_px": config.autoScrollStepPx,
            "intended_path_px": Double(config.fixedCommandCount ?? 0) * config.autoScrollStepPx,
            "observed_path_px": fixedWorkloadObservedPathPx,
            "warm_rounds": fixedWorkloadWarmRounds,
            "screen_maximum_frames_per_second": screenMaximumFramesPerSecond,
            "completed": fixedWorkloadCompleted,
            "loaded_count": workloadLoadedCount,
            "total_count": workloadTotalCount,
            "can_load_more": workloadCanLoadMore
        ]
        if let workloadDatasetMetadata {
            fixedWorkloadPayload["dataset"] = workloadDatasetMetadata.jsonPayload
        }

        var payload = callbackMetrics
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        payload["profile_scenario"] = env["SCOPY_PROFILE_SCENARIO"] ?? ""
        payload["duration_seconds"] = elapsedSeconds
        payload["scroll_speed_px_per_sec"] = speedPayload
        payload["timing_buckets_ms"] = bucketStats
        payload["buckets_ms"] = bucketStats
        payload["timing_event_count"] = timingEvents.totalCount
        payload["metric_event_count"] = timingEvents.totalCount
        payload["timing_event_retention"] = [
            "retained_count": timingEvents.retainedCount,
            "total_count": timingEvents.totalCount,
            "overwritten_count": timingEvents.overwrittenCount
        ]
        payload[MetricName.longAnimationCallbackAttribution] = longAnimationCallbackAttribution
        payload["long_frame_attribution"] = legacyLongFrameAttribution
        payload["main_runloop_active_ms"] = mainRunLoopPayload
        payload["main_runloop_event_count"] = mainRunLoopEvents.totalCount
        payload["main_runloop_event_retention"] = [
            "retained_count": mainRunLoopEvents.retainedCount,
            "total_count": mainRunLoopEvents.totalCount,
            "overwritten_count": mainRunLoopEvents.overwrittenCount
        ]
        payload[MetricName.mainThreadLongAnimationCallbackAttribution] =
            mainThreadLongAnimationCallbackAttribution
        payload["main_thread_long_frame_attribution"] = legacyMainThreadLongFrameAttribution
        payload["structural_metrics"] = structuralPayload
        payload["counters"] = structuralMetrics.counters
        payload["gauges"] = structuralMetrics.gauges
        payload["metric_semantics"] = Self.metricSemanticsPayload
        payload["accessibility_tree"] = accessibilityTree
        payload["scroll_sample_health"] = sampleHealthPayload
        payload["config"] = configPayload
        payload["fixed_workload"] = fixedWorkloadPayload

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        let url = URL(fileURLWithPath: config.outputPath)
        try? data.write(to: url, options: .atomic)
    }

    static func buildAnimationCallbackMetricPayload(
        intervalsMs: [Double],
        samples: [AnimationCallbackSample],
        expectedIntervalMs: Double,
        thresholdMultiplier: Double
    ) -> [String: Any] {
        let activeIntervalsMs = samples
            .filter(Self.isActiveAnimationCallback)
            .map(\.intervalMs)
        let intervalStats = Self.statsPayload(intervalsMs)
        let activeIntervalStats = Self.statsPayload(activeIntervalsMs)
        let thresholdMs = expectedIntervalMs > 0 && thresholdMultiplier > 0
            ? expectedIntervalMs * thresholdMultiplier
            : 0
        let overThresholdRatio = Self.overThresholdRatio(
            intervalsMs,
            thresholdMs: thresholdMs
        )
        let activeOverThresholdRatio = Self.overThresholdRatio(
            activeIntervalsMs,
            thresholdMs: thresholdMs
        )

        return [
            MetricName.animationCallbackInterval: intervalStats,
            MetricName.expectedAnimationCallbackInterval: expectedIntervalMs,
            MetricName.animationCallbackOverThresholdRatio: overThresholdRatio,
            MetricName.activeAnimationCallbackInterval: activeIntervalStats,
            MetricName.activeAnimationCallbackOverThresholdRatio: activeOverThresholdRatio,
            // Deprecated compatibility aliases consumed by the existing profile scripts.
            "frame_ms": intervalStats,
            "expected_frame_ms": expectedIntervalMs,
            "drop_ratio": overThresholdRatio,
            "active_frame_ms": activeIntervalStats,
            "active_drop_ratio": activeOverThresholdRatio
        ]
    }

    private static func applyRetentionMetadata(
        to payload: inout [String: Any],
        metricName: String,
        retainedCount: Int,
        totalCount: Int,
        overwrittenCount: Int,
        totalMs: Double
    ) {
        guard var metric = payload[metricName] as? [String: Any] else { return }
        metric["count"] = totalCount
        metric["retained_count"] = retainedCount
        metric["total_count"] = totalCount
        metric["overwritten_count"] = overwrittenCount
        metric["total_ms"] = totalMs
        metric["avg"] = totalCount > 0 ? totalMs / Double(totalCount) : 0
        if overwrittenCount > 0 {
            metric.removeValue(forKey: "p95")
        }
        payload[metricName] = metric
    }

    private static func removePercentile95(
        from payload: inout [String: Any],
        metricNames: [String]
    ) {
        for metricName in metricNames {
            guard var metric = payload[metricName] as? [String: Any] else { continue }
            metric.removeValue(forKey: "p95")
            payload[metricName] = metric
        }
    }

    static var metricSemanticsPayload: [String: Any] {
        [
            "animation_callback_interval_ms": "NSScreen CADisplayLink intervals for fixed workloads; TimelineView(.animation) intervals otherwise. These are callback intervals, not presented-frame timing or FPS.",
            "animation_callback_over_threshold_ratio": "Callback intervals above the configured threshold; not compositor frame drops.",
            "main_runloop_active_ms": "Main run-loop pressure proxy with exact whole-run total_count/total_ms; p95 is emitted only when overwritten_count is zero.",
            "timing_buckets_ms": "Each bucket has exact whole-run total_count/total_ms plus bounded retained samples; p95 is emitted only when overwritten_count is zero.",
            "counters": "Monotonic integer structural event totals.",
            "gauges": "Latest integer structural state values.",
            "compatibility_aliases": [
                "frame_ms": MetricName.animationCallbackInterval,
                "expected_frame_ms": MetricName.expectedAnimationCallbackInterval,
                "drop_ratio": MetricName.animationCallbackOverThresholdRatio,
                "active_frame_ms": MetricName.activeAnimationCallbackInterval,
                "active_drop_ratio": MetricName.activeAnimationCallbackOverThresholdRatio,
                "buckets_ms": "timing_buckets_ms",
                "metric_event_count": "timing_event_count",
                "long_frame_attribution": MetricName.longAnimationCallbackAttribution,
                "main_thread_long_frame_attribution": MetricName.mainThreadLongAnimationCallbackAttribution
            ]
        ]
    }

    static func buildLongAnimationCallbackAttribution(
        callbackSamples: [AnimationCallbackSample],
        timingEvents: [TimingEvent],
        expectedCallbackIntervalMs: Double,
        thresholdMultiplier: Double,
        maxCallbackDetails: Int,
        timelineStart: TimeInterval?
    ) -> [String: Any] {
        guard expectedCallbackIntervalMs > 0, thresholdMultiplier > 0 else {
            return [
                "threshold_ms": 0,
                "long_callback_count": 0,
                "timing_event_count": timingEvents.count,
                "total_callback_interval_ms": 0,
                "attributed_union_ms": 0,
                "unattributed_ms": 0,
                "attribution_coverage_ratio": 0,
                "top_metrics": [],
                "callbacks": []
            ]
        }

        let thresholdMs = expectedCallbackIntervalMs * thresholdMultiplier
        let longCallbacks = callbackSamples.filter { sample in
            guard sample.intervalMs > thresholdMs else { return false }
            return isActiveAnimationCallback(sample)
        }
        let detailCallbackIndexes = Set(
            longCallbacks
                .sorted { $0.intervalMs > $1.intervalMs }
                .prefix(maxCallbackDetails)
                .map(\.index)
        )
        var aggregateByMetric: [String: MetricAggregate] = [:]
        var detailCallbacks: [[String: Any]] = []
        var totalLongCallbackIntervalMs = 0.0
        var attributedUnionMs = 0.0

        for callback in longCallbacks {
            totalLongCallbackIntervalMs += callback.intervalMs
            let eventUnionOverlapMs = unionOverlapMs(timingEvents, overlapping: callback)
            attributedUnionMs += eventUnionOverlapMs
            let callbackAggregates = aggregateEvents(
                timingEvents,
                overlapping: callback,
                into: &aggregateByMetric
            )

            if detailCallbackIndexes.contains(callback.index) {
                detailCallbacks.append(
                    animationCallbackPayload(
                        callback,
                        thresholdMs: thresholdMs,
                        timelineStart: timelineStart,
                        eventUnionOverlapMs: eventUnionOverlapMs,
                        aggregates: callbackAggregates
                    )
                )
            }
        }
        detailCallbacks.sort {
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

        let unattributedMs = max(0, totalLongCallbackIntervalMs - attributedUnionMs)
        let attributionCoverageRatio = totalLongCallbackIntervalMs > 0
            ? min(1, attributedUnionMs / totalLongCallbackIntervalMs)
            : 0
        return [
            "threshold_ms": thresholdMs,
            "long_callback_count": longCallbacks.count,
            "timing_event_count": timingEvents.count,
            "total_callback_interval_ms": totalLongCallbackIntervalMs,
            "attributed_union_ms": attributedUnionMs,
            "unattributed_ms": unattributedMs,
            "attribution_coverage_ratio": attributionCoverageRatio,
            "top_metrics": Array(topMetrics),
            "callbacks": detailCallbacks
        ]
    }

    static func buildLongFrameAttribution(
        frameSamples: [FrameSample],
        metricEvents: [MetricEvent],
        expectedFrameMs: Double,
        dropThresholdMultiplier: Double,
        maxFrameDetails: Int,
        timelineStart: TimeInterval?
    ) -> [String: Any] {
        let canonical = buildLongAnimationCallbackAttribution(
            callbackSamples: frameSamples,
            timingEvents: metricEvents,
            expectedCallbackIntervalMs: expectedFrameMs,
            thresholdMultiplier: dropThresholdMultiplier,
            maxCallbackDetails: maxFrameDetails,
            timelineStart: timelineStart
        )
        return legacyLongFrameAttribution(from: canonical)
    }

    static func legacyLongFrameAttribution(from canonical: [String: Any]) -> [String: Any] {
        var legacy = canonical
        legacy["long_frame_count"] = canonical["long_callback_count"] ?? 0
        legacy["metric_event_count"] = canonical["timing_event_count"] ?? 0
        legacy["total_frame_ms"] = canonical["total_callback_interval_ms"] ?? 0

        if let metrics = canonical["top_metrics"] as? [[String: Any]] {
            legacy["top_metrics"] = metrics.map { metric in
                var legacyMetric = metric
                legacyMetric["frame_count"] = metric["callback_count"] ?? 0
                return legacyMetric
            }
        }
        if let callbacks = canonical["callbacks"] as? [[String: Any]] {
            legacy["frames"] = callbacks.map { callback in
                var legacyCallback = callback
                legacyCallback["index"] = callback["callback_index"] ?? 0
                return legacyCallback
            }
        } else {
            legacy["frames"] = []
        }
        return legacy
    }

    private static func isActiveAnimationCallback(_ sample: AnimationCallbackSample) -> Bool {
        sample.isScrolling || (sample.offsetDelta ?? 0) > 0
    }

    private func startAutoScrollIfNeeded(_ scrollView: NSScrollView) {
        guard config.autoScrollEnabled else { return }
        if let fixedCommandCount = config.fixedCommandCount {
            guard fixedDisplayLinkDriver == nil else { return }
            let driver = FixedDisplayLinkDriver(
                owner: self,
                scrollView: scrollView,
                targetCommands: fixedCommandCount,
                step: CGFloat(config.autoScrollStepPx),
                warmRounds: config.warmRoundCount
            )
            fixedDisplayLinkDriver = driver
            driver.start()
            return
        }
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

    private func installStartNotificationObserverIfNeeded() {
        guard !isStartNotificationObserverInstalled,
              let rawName = config.startNotificationName else { return }
        isStartNotificationObserverInstalled = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStartNotification(_:)),
            name: Notification.Name(rawName),
            object: nil
        )
    }

    @objc private func handleStartNotification(_ notification: Notification) {
        guard !didReceiveStartNotification else { return }
        didReceiveStartNotification = true
        removeStartNotificationObserverIfNeeded()
        guard let scrollView else { return }
        startAutoScrollIfNeeded(scrollView)
    }

    private func removeStartNotificationObserverIfNeeded() {
        guard isStartNotificationObserverInstalled else { return }
        if let rawName = config.startNotificationName {
            DistributedNotificationCenter.default().removeObserver(
                self,
                name: Notification.Name(rawName),
                object: nil
            )
        }
        isStartNotificationObserverInstalled = false
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
        removeStartNotificationObserverIfNeeded()
        fixedDisplayLinkDriver?.invalidate()
        fixedDisplayLinkDriver = nil
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        if config.autoScrollEnabled {
            scrollDidEnd()
        }
    }

    private func fixedWorkloadDidBegin(
        warmRounds: Int,
        screenMaximumFramesPerSecond: Int,
        at timestamp: TimeInterval
    ) {
        let ingressTransition = Self.measurementEpoch.begin(
            at: timestamp,
            whileLocked: {
                _ = Self.queuedRecords.closeAndTakePendingForFinalization()
                Self.queuedRecords.reopenDiscardingPending()
            }
        )
        resetMeasurementStateForFixedWorkload()
        measurementGeneration = ingressTransition.snapshot.generation
        fixedWorkloadCommandCount = 0
        fixedWorkloadObservedPathPx = 0
        fixedWorkloadCompleted = false
        fixedWorkloadMeasuredCommandResponseCount = 0
        fixedWorkloadPreMeasurementSettleCallbackCount = 0
        fixedWorkloadPostMeasurementSettleCallbackCount = 0
        fixedWorkloadFinalizationState = "measuring"
        fixedWorkloadWarmRounds = warmRounds
        self.screenMaximumFramesPerSecond = screenMaximumFramesPerSecond
        for counterName in Self.fixedWorkloadRequiredCounterNames {
            structuralMetrics.registerCounter(name: counterName)
        }
        publishPassivePathGauges()
        structuralMetrics.setGauge(name: "fixed_workload.command_target", value: config.fixedCommandCount ?? 0)
        structuralMetrics.setGauge(name: "fixed_workload.step_px", value: Int(config.autoScrollStepPx.rounded()))
        structuralMetrics.setGauge(name: "fixed_workload.warm_rounds", value: warmRounds)
        structuralMetrics.setGauge(
            name: "fixed_workload.intended_path_px",
            value: Int(Double(config.fixedCommandCount ?? 0) * config.autoScrollStepPx)
        )
        structuralMetrics.setGauge(
            name: "fixed_workload.screen_maximum_fps",
            value: screenMaximumFramesPerSecond
        )
        scrollDidStart()
        startTimestamp = timestamp
    }

    private func publishPassivePathGauges() {
        structuralMetrics.setGauge(
            name: Self.activeSlotCurrentGauge,
            value: latestActiveSlotCount
        )
        structuralMetrics.recordMaximumGauge(
            name: Self.activeSlotMaximumGauge,
            value: latestActiveSlotCount
        )
        structuralMetrics.setGauge(
            name: Self.suppressedCandidateCurrentGauge,
            value: latestSuppressedCandidateCount
        )
        structuralMetrics.recordMaximumGauge(
            name: Self.suppressedCandidateMaximumGauge,
            value: latestSuppressedCandidateCount
        )
    }

    private func resetMeasurementStateForFixedWorkload() {
        stopMainRunLoopObserverIfNeeded(at: Date().timeIntervalSinceReferenceDate)
        startTimestamp = nil
        lastAnimationCallbackTimestamp = nil
        lastScrollOffset = scrollView?.contentView.bounds.origin.y
        expectedAnimationCallbackIntervalMs = config.expectedAnimationCallbackIntervalMs
        animationCallbackIntervalsMs = BoundedRingBuffer(capacity: config.maxSamples)
        animationCallbackIntervalTotalMs = 0
        scrollSpeedSamples = BoundedRingBuffer(capacity: config.maxSamples)
        timingBuckets.removeAll(keepingCapacity: true)
        timingEvents = BoundedRingBuffer(capacity: config.maxSamples)
        animationCallbackSamples = BoundedRingBuffer(capacity: config.maxSamples)
        mainRunLoopActiveDurationsMs.reset()
        mainRunLoopEvents = BoundedRingBuffer(capacity: config.maxSamples)
        structuralMetrics = ScrollProfileStructuralMetrics()
        animationCallbackSequence = 0
        isScrolling = false
    }

    private func fixedWorkloadCommandDidExecute(observedDelta: CGFloat) {
        fixedWorkloadCommandCount += 1
        fixedWorkloadObservedPathPx += Double(observedDelta)
        if fixedWorkloadCommandCount == config.fixedCommandCount {
            fixedWorkloadFinalizationState = "last_command_issued"
        }
        structuralMetrics.setGauge(
            name: "fixed_workload.command_count",
            value: fixedWorkloadCommandCount
        )
        structuralMetrics.setGauge(
            name: "fixed_workload.observed_path_px",
            value: Int(fixedWorkloadObservedPathPx.rounded())
        )
    }

    private func fixedWorkloadDidComplete(sequencer: FixedWorkloadCallbackSequencer) {
        let completionTimestamp = Date().timeIntervalSinceReferenceDate
        fixedWorkloadMeasuredCommandResponseCount = sequencer.measuredCommandResponseCount
        fixedWorkloadPreMeasurementSettleCallbackCount = sequencer.preMeasurementSettleCallbackCount
        fixedWorkloadPostMeasurementSettleCallbackCount = sequencer.postMeasurementSettleCallbackCount
        fixedWorkloadFinalizationState = "response_captured"
        // Cross the same lock-serialized ingress boundary as background/static producers before
        // closing the measurement window. Queued pre-completion records are applied while the
        // fixed workload is still live, so they cannot be rejected by the completion guard.
        closeMeasurementIngressAndDrainQueuedRecords()
        fixedWorkloadFinalizationState = "response_captured_and_drained"
        fixedWorkloadCompleted = true
        scrollDidEnd()
        maybeFinalize(now: completionTimestamp)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.maybeFinalize(now: Date().timeIntervalSinceReferenceDate)
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
        mainRunLoopActiveDurationsMs.append(durationMs)
        mainRunLoopEvents.append(
            TimingEvent(
                name: "main.runloop_active_ms",
                start: start,
                end: timestamp,
                durationMs: durationMs
            )
        )
    }

    private static func aggregateEvents(
        _ events: [TimingEvent],
        overlapping callback: AnimationCallbackSample,
        into globalAggregate: inout [String: MetricAggregate]
    ) -> [String: MetricAggregate] {
        var callbackAggregate: [String: MetricAggregate] = [:]

        for event in events {
            guard event.end >= callback.start, event.start <= callback.end else { continue }
            let overlapSeconds = min(event.end, callback.end) - max(event.start, callback.start)
            let overlapMs = max(0, overlapSeconds * 1000)
            guard overlapMs > 0 || (event.end >= callback.start && event.end <= callback.end) else {
                continue
            }

            callbackAggregate[event.name, default: MetricAggregate()]
                .add(event: event, overlapMs: overlapMs, callbackIndex: callback.index)
            globalAggregate[event.name, default: MetricAggregate()]
                .add(event: event, overlapMs: overlapMs, callbackIndex: callback.index)
        }

        return callbackAggregate
    }

    private static func unionOverlapMs(
        _ events: [TimingEvent],
        overlapping callback: AnimationCallbackSample
    ) -> Double {
        var intervals: [(start: TimeInterval, end: TimeInterval)] = []
        intervals.reserveCapacity(events.count)

        for event in events {
            let start = max(event.start, callback.start)
            let end = min(event.end, callback.end)
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

        return min(callback.intervalMs, max(0, totalSeconds * 1000))
    }

    private static func animationCallbackPayload(
        _ callback: AnimationCallbackSample,
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
            "callback_index": callback.index,
            "interval_ms": callback.intervalMs,
            "threshold_ms": thresholdMs,
            "event_count": aggregates.values.reduce(0) { $0 + $1.count },
            "event_overlap_ms": aggregates.values.reduce(0) { $0 + $1.overlapMs },
            "event_union_overlap_ms": eventUnionOverlapMs,
            "unattributed_ms": max(0, callback.intervalMs - eventUnionOverlapMs),
            "attribution_coverage_ratio": callback.intervalMs > 0
                ? min(1, eventUnionOverlapMs / callback.intervalMs)
                : 0,
            "is_scrolling": callback.isScrolling,
            "top_events": Array(topEvents)
        ]
        if let timelineStart {
            payload["start_ms"] = (callback.start - timelineStart) * 1000
            payload["end_ms"] = (callback.end - timelineStart) * 1000
        }
        if let offsetDelta = callback.offsetDelta {
            payload["offset_delta_px"] = offsetDelta
        }
        if let scrollSpeed = callback.scrollSpeed {
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

    private static func statsPayload(_ samples: [Double]) -> [String: Any] {
        let stats = computeStats(samples)
        return [
            "count": stats.count,
            "min": stats.min,
            "avg": stats.avg,
            "p50": stats.p50,
            "p95": stats.p95,
            "max": stats.max
        ]
    }

    private static func overThresholdRatio(_ samples: [Double], thresholdMs: Double) -> Double {
        guard thresholdMs > 0, !samples.isEmpty else { return 0 }
        let overThresholdCount = samples.reduce(into: 0) { count, sample in
            if sample > thresholdMs {
                count += 1
            }
        }
        return Double(overThresholdCount) / Double(samples.count)
    }

    private static func computeStats(
        _ samples: [Double]
    ) -> (count: Int, min: Double, max: Double, avg: Double, p50: Double, p95: Double) {
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

    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count) * p / 100)
        return sorted[min(index, sorted.count - 1)]
    }
}
