import XCTest
import ScopyKit

/// PerformanceProfiler 单元测试
/// 验证性能测量、统计指标计算和报告生成
@MainActor
final class PerformanceProfilerTests: XCTestCase {

    var profiler: PerformanceProfiler!

    override func setUp() async throws {
        profiler = PerformanceProfiler.shared
        profiler.enable()
        profiler.startProfiling()
    }

    override func tearDown() async throws {
        _ = profiler.stopProfiling()
        profiler = nil
    }

    // MARK: - Test 1: Synchronous Measure

    func testSynchronousMeasure() async throws {
        let result = profiler.measure("sync_test") {
            // Simulate some work
            var sum = 0
            for i in 0..<1000 {
                sum += i
            }
            return sum
        }

        XCTAssertEqual(result, 499500, "Computation result should be correct")

        let metrics = profiler.getCurrentMetrics()
        let syncMetric = metrics.first { $0.name == "sync_test" }

        XCTAssertNotNil(syncMetric, "Should have sync_test metric")
        XCTAssertEqual(syncMetric?.count, 1, "Should have 1 measurement")
        XCTAssertGreaterThan(syncMetric?.avg ?? 0, 0, "Average should be > 0")
    }

    // MARK: - Test 2: Asynchronous Measure

    func testAsynchronousMeasure() async throws {
        let result = await profiler.measureAsync("async_test") {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return 42
        }

        XCTAssertEqual(result, 42, "Async result should be correct")

        let metrics = profiler.getCurrentMetrics()
        let asyncMetric = metrics.first { $0.name == "async_test" }

        XCTAssertNotNil(asyncMetric, "Should have async_test metric")
        XCTAssertGreaterThanOrEqual(asyncMetric?.avg ?? 0, 5, "Should be at least 5ms")
    }

    // MARK: - Test 3: Statistical Metrics (min/max/avg/percentiles)

    func testStatisticalMetrics() async throws {
        // Record known values for predictable statistics
        let testValues: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

        for value in testValues {
            profiler.record(name: "stats_test", value: value)
        }

        let metrics = profiler.getCurrentMetrics()
        let statsMetric = metrics.first { $0.name == "stats_test" }

        XCTAssertNotNil(statsMetric)
        XCTAssertEqual(statsMetric?.count, 10)
        XCTAssertEqual(statsMetric?.min, 10, "Min should be 10")
        XCTAssertEqual(statsMetric?.max, 100, "Max should be 100")
        XCTAssertEqual(statsMetric?.avg, 55, "Average should be 55")
        XCTAssertEqual(statsMetric?.p50 ?? 0, 50, accuracy: 10, "P50 should be ~50")
        XCTAssertGreaterThanOrEqual(statsMetric?.p95 ?? 0, 90, "P95 should be >= 90")
        XCTAssertGreaterThanOrEqual(statsMetric?.p99 ?? 0, 95, "P99 should be >= 95")
    }

    // MARK: - Test 4: Report Generation

    func testReportGeneration() async throws {
        profiler.record(name: "report_test", value: 25.5)
        profiler.record(name: "report_test", value: 30.0)

        let report = profiler.stopProfiling()

        XCTAssertFalse(report.metrics.isEmpty, "Report should have metrics")
        XCTAssertTrue(report.duration >= 0, "Duration should be non-negative")

        let description = report.description
        XCTAssertTrue(description.contains("Performance Profile Report"), "Should have title")
        XCTAssertTrue(description.contains("report_test"), "Should contain metric name")
        XCTAssertTrue(description.contains("Avg"), "Should contain average label")
        XCTAssertTrue(description.contains("P95"), "Should contain P95 label")
    }

    // MARK: - Test 5: Benchmark Runner

    func testBenchmarkRunner() async throws {
        let runner = BenchmarkRunner()

        runner.runBenchmark(
            name: "simple_bench",
            iterations: 50,
            targetMs: 1.0,
            warmup: 5
        ) {
            // Simple operation
            _ = [Int](repeating: 0, count: 100)
        }

        let report = runner.generateReport()

        XCTAssertTrue(report.contains("Benchmark Results"), "Should have title")
        XCTAssertTrue(report.contains("simple_bench"), "Should contain benchmark name")
        XCTAssertTrue(runner.allPassed(), "Simple benchmark should pass")
    }

    // MARK: - Test 6: Async Benchmark Runner

    func testAsyncBenchmarkRunner() async throws {
        let runner = BenchmarkRunner()

        await runner.runAsyncBenchmark(
            name: "async_bench",
            iterations: 10,
            targetMs: 50.0,
            warmup: 2
        ) {
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

        let report = runner.generateReport()

        XCTAssertTrue(report.contains("async_bench"))
        XCTAssertTrue(runner.allPassed(), "Async benchmark should pass")
    }

    // MARK: - Test 7: Profiler Enable/Disable

    func testEnableDisable() async throws {
        profiler.disable()

        // Measure while disabled should still work but not record
        let result = profiler.measure("disabled_test") {
            return 123
        }

        XCTAssertEqual(result, 123, "Should return result even when disabled")

        let metrics = profiler.getCurrentMetrics()
        let disabledMetric = metrics.first { $0.name == "disabled_test" }

        XCTAssertNil(disabledMetric, "Should not record metrics when disabled")

        // Re-enable
        profiler.enable()

        _ = profiler.measure("enabled_test") {
            return 456
        }

        let newMetrics = profiler.getCurrentMetrics()
        let enabledMetric = newMetrics.first { $0.name == "enabled_test" }

        XCTAssertNotNil(enabledMetric, "Should record metrics when enabled")
    }

    // MARK: - Test 8: Edge Case - Empty Metrics

    func testEmptyMetrics() async throws {
        // No measurements recorded
        let metrics = profiler.getCurrentMetrics()
        XCTAssertTrue(metrics.isEmpty, "Should have no metrics initially")

        let report = profiler.stopProfiling()
        XCTAssertTrue(report.metrics.isEmpty, "Report should have empty metrics")

        // Test Metric struct with empty values
        let emptyMetric = PerformanceProfiler.Metric(name: "empty", values: [])
        XCTAssertEqual(emptyMetric.count, 0)
        XCTAssertEqual(emptyMetric.min, 0)
        XCTAssertEqual(emptyMetric.max, 0)
        XCTAssertEqual(emptyMetric.avg, 0)
        XCTAssertEqual(emptyMetric.p50, 0)
        XCTAssertEqual(emptyMetric.p95, 0)
        XCTAssertEqual(emptyMetric.p99, 0)
    }

    // MARK: - Test 9: Many Measurements

    func testManyMeasurements() async throws {
        // Record 1000 measurements
        for i in 0..<1000 {
            profiler.record(name: "bulk_test", value: Double(i % 100))
        }

        let metrics = profiler.getCurrentMetrics()
        let bulkMetric = metrics.first { $0.name == "bulk_test" }

        XCTAssertNotNil(bulkMetric)
        XCTAssertEqual(bulkMetric?.count, 1000, "Should have 1000 measurements")

        // Verify percentiles are calculated correctly
        XCTAssertGreaterThan(bulkMetric?.p50 ?? 0, 40, "P50 should be around 49-50")
        XCTAssertLessThan(bulkMetric?.p50 ?? 100, 60, "P50 should be around 49-50")
    }
}

// MARK: - Performance Assertions Tests

@MainActor
final class PerformanceAssertionsTests: XCTestCase {

    func testSearchLatencyAssertions() async throws {
        // Test assertions for different item counts
        // These should not crash, just print warnings if exceeded

        // Small dataset - target 50ms
        PerformanceAssertions.assertSearchLatency(30, itemCount: 1000)
        PerformanceAssertions.assertSearchLatency(60, itemCount: 1000) // Should warn

        // Medium dataset - target 150ms
        PerformanceAssertions.assertSearchLatency(100, itemCount: 50000)
        PerformanceAssertions.assertSearchLatency(200, itemCount: 50000) // Should warn

        // Large dataset - target 300ms
        PerformanceAssertions.assertSearchLatency(250, itemCount: 200000)

        // This test passes if no crashes occur
        XCTAssertTrue(true)
    }

    func testFetchLatencyAssertions() async throws {
        // Test fetch latency assertions
        PerformanceAssertions.assertFetchLatency(10, limit: 50)
        PerformanceAssertions.assertFetchLatency(100, limit: 50) // Should warn

        XCTAssertTrue(true)
    }
}
