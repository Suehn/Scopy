import Foundation

/// 性能分析器 - 用于收集和报告性能指标
/// 符合 v0.md 第4节的性能监控要求
@MainActor
public final class PerformanceProfiler {
    // MARK: - Types

    public struct Metric {
        public let name: String
        public let values: [Double]

        public init(name: String, values: [Double]) {
            self.name = name
            self.values = values
        }

        public var count: Int { values.count }
        public var min: Double { values.min() ?? 0 }
        public var max: Double { values.max() ?? 0 }
        public var avg: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

        public func percentile(_ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int(Double(sorted.count) * p / 100)
            return sorted[Swift.min(index, sorted.count - 1)]
        }

        public var p50: Double { percentile(50) }
        public var p95: Double { percentile(95) }
        public var p99: Double { percentile(99) }
    }

    public struct ProfileReport: CustomStringConvertible {
        public let metrics: [Metric]
        public let timestamp: Date
        public let duration: TimeInterval

        public var description: String {
            var lines = [String]()
            lines.append("╔═══════════════════════════════════════════════════════════════╗")
            lines.append("║              Performance Profile Report                        ║")
            lines.append("╠═══════════════════════════════════════════════════════════════╣")
            lines.append("║ Generated: \(formatDate(timestamp))")
            lines.append("║ Duration: \(String(format: "%.2f", duration))s")
            lines.append("╠═══════════════════════════════════════════════════════════════╣")

            for metric in metrics {
                lines.append("║")
                lines.append("║ \(metric.name)")
                lines.append("║   Count: \(metric.count)")
                lines.append("║   Min:   \(String(format: "%.2f", metric.min))ms")
                lines.append("║   Avg:   \(String(format: "%.2f", metric.avg))ms")
                lines.append("║   P50:   \(String(format: "%.2f", metric.p50))ms")
                lines.append("║   P95:   \(String(format: "%.2f", metric.p95))ms")
                lines.append("║   P99:   \(String(format: "%.2f", metric.p99))ms")
                lines.append("║   Max:   \(String(format: "%.2f", metric.max))ms")
            }

            lines.append("╚═══════════════════════════════════════════════════════════════╝")
            return lines.joined(separator: "\n")
        }

        private func formatDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
    }

    // MARK: - Properties

    private var measurements: [String: [Double]] = [:]
    private var startTime: Date?
    private var isEnabled = true

    public static let shared = PerformanceProfiler()

    private init() {}

    // MARK: - Public API

    public func enable() { isEnabled = true }
    public func disable() { isEnabled = false }

    public func startProfiling() {
        measurements.removeAll()
        startTime = Date()
    }

    public func stopProfiling() -> ProfileReport {
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let metrics = measurements.map { Metric(name: $0.key, values: $0.value) }
            .sorted { $0.name < $1.name }

        return ProfileReport(
            metrics: metrics,
            timestamp: Date(),
            duration: duration
        )
    }

    /// Record a timing measurement
    @discardableResult
    public func measure<T>(_ name: String, block: () throws -> T) rethrows -> T {
        guard isEnabled else { return try block() }

        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            record(name: name, value: elapsed)
        }
        return try block()
    }

    /// Record an async timing measurement
    @discardableResult
    public func measureAsync<T: Sendable>(_ name: String, block: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await block() }

        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            record(name: name, value: elapsed)
        }
        return try await block()
    }

    /// Manually record a measurement
    public func record(name: String, value: Double) {
        measurements[name, default: []].append(value)
    }

    /// Get current metrics without stopping
    public func getCurrentMetrics() -> [Metric] {
        measurements.map { Metric(name: $0.key, values: $0.value) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Convenience Methods

    /// Profile a storage operation
    func profileStorage<T>(operation: String, block: () throws -> T) rethrows -> T {
        try measure("Storage.\(operation)", block: block)
    }

    /// Profile a search operation
    func profileSearch<T: Sendable>(mode: SearchMode, block: () async throws -> T) async rethrows -> T {
        try await measureAsync("Search.\(mode.rawValue)", block: block)
    }

    /// Profile a clipboard operation
    func profileClipboard<T>(operation: String, block: () throws -> T) rethrows -> T {
        try measure("Clipboard.\(operation)", block: block)
    }
}

// MARK: - Benchmark Runner

/// 基准测试运行器
@MainActor
public final class BenchmarkRunner {
    public struct BenchmarkResult {
        public let name: String
        public let iterations: Int
        public let totalTimeMs: Double
        public let avgTimeMs: Double
        public let opsPerSecond: Double
        public let passed: Bool
        public let targetMs: Double?
    }

    private var results: [BenchmarkResult] = []

    public init() {}

    public func runBenchmark(
        name: String,
        iterations: Int = 100,
        targetMs: Double? = nil,
        warmup: Int = 10,
        block: () throws -> Void
    ) rethrows {
        // Warmup
        for _ in 0..<warmup {
            try block()
        }

        // Actual benchmark
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try block()
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let avg = elapsed / Double(iterations)
        let passed = targetMs.map { avg <= $0 } ?? true

        results.append(BenchmarkResult(
            name: name,
            iterations: iterations,
            totalTimeMs: elapsed,
            avgTimeMs: avg,
            opsPerSecond: Double(iterations) / (elapsed / 1000),
            passed: passed,
            targetMs: targetMs
        ))
    }

    public func runAsyncBenchmark(
        name: String,
        iterations: Int = 100,
        targetMs: Double? = nil,
        warmup: Int = 10,
        block: () async throws -> Void
    ) async rethrows {
        // Warmup
        for _ in 0..<warmup {
            try await block()
        }

        // Actual benchmark
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try await block()
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let avg = elapsed / Double(iterations)
        let passed = targetMs.map { avg <= $0 } ?? true

        results.append(BenchmarkResult(
            name: name,
            iterations: iterations,
            totalTimeMs: elapsed,
            avgTimeMs: avg,
            opsPerSecond: Double(iterations) / (elapsed / 1000),
            passed: passed,
            targetMs: targetMs
        ))
    }

    public func generateReport() -> String {
        var lines = [String]()
        lines.append("")
        lines.append("╔═══════════════════════════════════════════════════════════════════════════╗")
        lines.append("║                         Benchmark Results                                   ║")
        lines.append("╠═══════════════════════════════════════════════════════════════════════════╣")
        lines.append("║ Name                          │ Avg (ms) │ Ops/s   │ Target  │ Status     ║")
        lines.append("╟───────────────────────────────┼──────────┼─────────┼─────────┼────────────╢")

        for result in results {
            let status = result.passed ? "✅ PASS" : "❌ FAIL"
            let target = result.targetMs.map { String(format: "%.1f", $0) } ?? "-"
            let name = result.name.padding(toLength: 29, withPad: " ", startingAt: 0)

            lines.append(String(
                format: "║ %@ │ %8.2f │ %7.0f │ %7@ │ %10@ ║",
                name, result.avgTimeMs, result.opsPerSecond, target, status
            ))
        }

        lines.append("╚═══════════════════════════════════════════════════════════════════════════╝")

        let passCount = results.filter { $0.passed }.count
        lines.append("")
        lines.append("Summary: \(passCount)/\(results.count) benchmarks passed")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    public func allPassed() -> Bool {
        results.allSatisfy { $0.passed }
    }
}

// MARK: - Performance Assertions

/// 性能断言宏
public struct PerformanceAssertions {
    /// Assert search latency meets v0.md requirements
    public static func assertSearchLatency(_ latencyMs: Double, itemCount: Int, file: StaticString = #file, line: UInt = #line) {
        let target: Double
        if itemCount <= 5000 {
            // v0.md 4.1: P95 ≤ 50ms for ≤5k items
            target = 50
        } else if itemCount <= 100_000 {
            // v0.md 4.1: P95 ≤ 100-150ms for 10k-100k items
            target = 150
        } else {
            target = 300 // Reasonable upper bound
        }

        if latencyMs > target {
            ScopyLog.search.warning(
                "Performance warning: search latency \(latencyMs, privacy: .public)ms exceeds target \(target, privacy: .public)ms for \(itemCount, privacy: .public) items (file: \(String(describing: file), privacy: .public):\(line, privacy: .public))"
            )
        }
    }

    /// Assert fetch latency is reasonable
    public static func assertFetchLatency(_ latencyMs: Double, limit: Int, file: StaticString = #file, line: UInt = #line) {
        // Generally, fetching should be under 20ms for typical page sizes
        let target = Double(limit) * 0.5 + 10 // Rough heuristic

        if latencyMs > target {
            ScopyLog.search.warning(
                "Performance warning: fetch latency \(latencyMs, privacy: .public)ms exceeds target \(target, privacy: .public)ms for limit \(limit, privacy: .public) (file: \(String(describing: file), privacy: .public):\(line, privacy: .public))"
            )
        }
    }
}
