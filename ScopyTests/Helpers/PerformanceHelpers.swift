import Foundation
import XCTest

// MARK: - Performance Measurement

/// 性能测量辅助工具
/// 提供统一的性能指标计算和报告
enum PerformanceHelpers {

    // MARK: - Timing Utilities

    /// 测量代码块执行时间
    static func measureTime<T>(
        _ block: () throws -> T
    ) rethrows -> (result: T, timeMs: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (result, elapsed)
    }

    /// 测量异步代码块执行时间
    static func measureTimeAsync<T>(
        _ block: () async throws -> T
    ) async rethrows -> (result: T, timeMs: Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return (result, elapsed)
    }

    /// 多次运行并收集时间样本
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

    /// 异步版本的样本收集
    static func collectTimeSamplesAsync(
        iterations: Int,
        warmupIterations: Int = 2,
        _ block: () async throws -> Void
    ) async rethrows -> [Double] {
        // Warmup
        for _ in 0..<warmupIterations {
            try await block()
        }

        // Collect samples
        var times: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try await block()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
        }

        return times
    }

    // MARK: - Statistics

    /// 计算性能统计数据
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

    // MARK: - Memory Measurement

    /// 获取当前内存使用量（字节）
    static func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    /// 测量代码块的内存增长
    static func measureMemoryGrowth<T>(
        _ block: () throws -> T
    ) rethrows -> (result: T, memoryGrowthBytes: Int) {
        let initialMemory = getCurrentMemoryUsage()
        let result = try block()
        let finalMemory = getCurrentMemoryUsage()
        return (result, finalMemory - initialMemory)
    }

    // MARK: - Formatting

    /// 格式化字节数
    static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    /// 格式化时间（毫秒）
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

// MARK: - Performance Stats

/// 性能统计数据
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

// MARK: - SLO Verification

/// v0.md SLO 验证辅助
enum SLOVerification {

    /// v0.md 4.1: 搜索延迟目标
    enum SearchLatency {
        case small    // ≤5k items: P95 ≤ 50ms
        case medium   // 10k-100k items: P95 ≤ 150ms

        var p95Target: Double {
            switch self {
            case .small: return 50
            case .medium: return 150
            }
        }

        var description: String {
            switch self {
            case .small: return "≤5k items"
            case .medium: return "10k-100k items"
            }
        }
    }

    /// 验证搜索延迟是否符合 SLO
    static func verifySearchLatency(
        stats: PerformanceStats,
        target: SearchLatency,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertLessThan(
            stats.p95,
            target.p95Target,
            "Search P95 (\(PerformanceHelpers.formatTime(stats.p95))) exceeds target " +
            "(\(PerformanceHelpers.formatTime(target.p95Target))) for \(target.description)",
            file: file,
            line: line
        )
    }

    /// v0.md 2.2: 首屏加载目标 (<100ms)
    static func verifyFirstScreenLoad(
        stats: PerformanceStats,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertLessThan(
            stats.p95,
            100,
            "First screen load P95 (\(PerformanceHelpers.formatTime(stats.p95))) exceeds 100ms target",
            file: file,
            line: line
        )
    }

    /// v0.md 4.2: 搜索防抖验证 (150-200ms)
    static let debounceRange = 150.0...200.0
}

// MARK: - XCTest Extensions

extension XCTestCase {

    /// 运行性能测试并返回统计数据
    @MainActor
    func runPerformanceTest(
        iterations: Int = 20,
        warmup: Int = 2,
        _ block: () async throws -> Void
    ) async throws -> PerformanceStats {
        let samples = try await PerformanceHelpers.collectTimeSamplesAsync(
            iterations: iterations,
            warmupIterations: warmup,
            block
        )
        return PerformanceHelpers.calculateStats(samples)
    }

    /// 验证性能是否在目标范围内
    func assertPerformance(
        _ stats: PerformanceStats,
        p95LessThan target: Double,
        message: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertLessThan(
            stats.p95,
            target,
            message.isEmpty ? "P95 (\(stats.p95)ms) exceeds target (\(target)ms)" : message,
            file: file,
            line: line
        )
    }
}
