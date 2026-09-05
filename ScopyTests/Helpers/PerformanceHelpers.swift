import Foundation

// Metrics consumed by PerformanceTests.
enum PerformanceHelpers {

    static func measureTime<T>(
        _ block: () throws -> T
    ) rethrows -> (result: T, timeMs: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (result, elapsed)
    }

    static func collectTimeSamples(
        iterations: Int,
        warmupIterations: Int = 2,
        _ block: () throws -> Void
    ) rethrows -> [Double] {
        // Warmup
        for _ in 0..<warmupIterations {
            try block()
        }

        // Collect samples
        var times: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try block()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
        }

        return times
    }

    static func calculateStats(_ samples: [Double]) -> PerformanceStats {
        guard !samples.isEmpty else {
            return PerformanceStats(
                min: 0, max: 0, mean: 0,
                median: 0, p95: 0, p99: 0,
                stdDev: 0, sampleCount: 0
            )
        }

        let sorted = samples.sorted()
        let count = sorted.count
        let sum = sorted.reduce(0, +)
        let mean = sum / Double(count)

        // Median
        let median: Double
        if count % 2 == 0 {
            median = (sorted[count/2 - 1] + sorted[count/2]) / 2
        } else {
            median = sorted[count/2]
        }

        // Percentiles
        let p95Index = Int(Double(count) * 0.95)
        let p99Index = Int(Double(count) * 0.99)
        let p95 = sorted[min(p95Index, count - 1)]
        let p99 = sorted[min(p99Index, count - 1)]

        // Standard Deviation
        let squaredDiffs = sorted.map { ($0 - mean) * ($0 - mean) }
        let variance = squaredDiffs.reduce(0, +) / Double(count)
        let stdDev = sqrt(variance)

        return PerformanceStats(
            min: sorted.first!,
            max: sorted.last!,
            mean: mean,
            median: median,
            p95: p95,
            p99: p99,
            stdDev: stdDev,
            sampleCount: count
        )
    }

    static func formatTime(_ ms: Double) -> String {
        if ms < 1 {
            return String(format: "%.2f μs", ms * 1000)
        }
        if ms < 1000 {
            return String(format: "%.2f ms", ms)
        }
        return String(format: "%.2f s", ms / 1000)
    }
}

struct PerformanceStats {
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
    let p95: Double
    let p99: Double
    let stdDev: Double
    let sampleCount: Int

    /// 生成格式化的报告字符串
    func report(title: String = "Performance") -> String {
        """
        📊 \(title):
           - Samples: \(sampleCount)
           - Min: \(PerformanceHelpers.formatTime(min))
           - Max: \(PerformanceHelpers.formatTime(max))
           - Mean: \(PerformanceHelpers.formatTime(mean))
           - Median: \(PerformanceHelpers.formatTime(median))
           - P95: \(PerformanceHelpers.formatTime(p95))
           - P99: \(PerformanceHelpers.formatTime(p99))
           - Std Dev: \(PerformanceHelpers.formatTime(stdDev))
        """
    }
}
