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

        static func load() -> Config {
            let env = ProcessInfo.processInfo.environment
            let enabled = parseBool(env["SCOPY_SCROLL_PROFILE"]) ?? false
            let durationSeconds = parseDouble(env["SCOPY_PROFILE_DURATION_SEC"]) ?? 6.0
            let minSamples = max(30, parseInt(env["SCOPY_PROFILE_MIN_SAMPLES"]) ?? 180)
            let outputPath = env["SCOPY_PROFILE_OUTPUT"] ?? "/tmp/scopy_scroll_profile.json"
            let dropThresholdMultiplier = parseDouble(env["SCOPY_PROFILE_DROP_THRESHOLD"]) ?? 1.5
            let expectedFrameMs = parseDouble(env["SCOPY_PROFILE_EXPECTED_FRAME_MS"])
            let maxSamples = max(500, parseInt(env["SCOPY_PROFILE_MAX_SAMPLES"]) ?? 2000)

            return Config(
                enabled: enabled,
                durationSeconds: durationSeconds,
                minSamples: minSamples,
                outputPath: outputPath,
                dropThresholdMultiplier: dropThresholdMultiplier,
                expectedFrameMs: expectedFrameMs,
                maxSamples: maxSamples
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

    private var frameIntervalsMs: [Double] = []
    private var scrollSpeedSamples: [Double] = []
    private var metricBuckets: [String: [Double]] = [:]

    private init() {
        self.config = Config.load()
        self.expectedFrameMs = config.expectedFrameMs
    }

    public func attachScrollView(_ scrollView: NSScrollView) {
        guard config.enabled else { return }
        self.scrollView = scrollView
    }

    public func scrollDidStart() {
        guard config.enabled else { return }
        isScrolling = true
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
        }

        lastFrameTimestamp = now
        lastScrollOffset = currentOffset
        maybeFinalize(now: now)
    }

    public func recordMetric(name: String, elapsedMs: Double) {
        guard config.enabled else { return }
        var bucket = metricBuckets[name, default: []]
        appendSample(elapsedMs, to: &bucket, limit: config.maxSamples)
        metricBuckets[name] = bucket
    }

    public nonisolated static func recordMetric(name: String, elapsedMs: Double) {
        guard isEnabled else { return }
        Task { @MainActor in
            shared.recordMetric(name: name, elapsedMs: elapsedMs)
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
        let frameStats = computeStats(frameIntervalsMs)
        let speedStats = computeStats(scrollSpeedSamples)
        let expected = expectedFrameMs ?? 0
        let dropRatio = frameIntervalsMs.isEmpty ? 0 : Double(dropCount) / Double(frameIntervalsMs.count)

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
            "scroll_speed_px_per_sec": [
                "count": speedStats.count,
                "min": speedStats.min,
                "avg": speedStats.avg,
                "p50": speedStats.p50,
                "p95": speedStats.p95,
                "max": speedStats.max
            ],
            "buckets_ms": bucketStats,
            "config": [
                "mock_item_count": env["SCOPY_MOCK_ITEM_COUNT"] ?? "",
                "mock_image_count": env["SCOPY_MOCK_IMAGE_COUNT"] ?? "",
                "mock_text_length": env["SCOPY_MOCK_TEXT_LENGTH"] ?? "",
                "mock_show_thumbnails": env["SCOPY_MOCK_SHOW_THUMBNAILS"] ?? "",
                "profile_accessibility": env["SCOPY_PROFILE_ACCESSIBILITY"] ?? ""
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        let url = URL(fileURLWithPath: config.outputPath)
        try? data.write(to: url, options: .atomic)
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
