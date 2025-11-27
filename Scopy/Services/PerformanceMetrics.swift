import Foundation

/// 性能指标收集器
/// 收集并计算搜索延迟、首屏加载等性能数据
/// 用于 About 页面显示真实性能指标
actor PerformanceMetrics {
    static let shared = PerformanceMetrics()

    // MARK: - Properties

    private var searchLatencies: [Double] = []
    private var loadLatencies: [Double] = []
    private let maxSamples = 100

    // MARK: - Recording

    /// 记录搜索延迟 (ms)
    func recordSearchLatency(_ ms: Double) {
        searchLatencies.append(ms)
        if searchLatencies.count > maxSamples {
            searchLatencies.removeFirst()
        }
    }

    /// 记录首屏加载延迟 (ms)
    func recordLoadLatency(_ ms: Double) {
        loadLatencies.append(ms)
        if loadLatencies.count > maxSamples {
            loadLatencies.removeFirst()
        }
    }

    // MARK: - Statistics

    /// 搜索延迟 P95 (ms)
    var searchP95: Double {
        calculateP95(searchLatencies)
    }

    /// 首屏加载 P95 (ms)
    var loadP95: Double {
        calculateP95(loadLatencies)
    }

    /// 搜索延迟平均值 (ms)
    var searchAvg: Double {
        guard !searchLatencies.isEmpty else { return 0 }
        return searchLatencies.reduce(0, +) / Double(searchLatencies.count)
    }

    /// 首屏加载平均值 (ms)
    var loadAvg: Double {
        guard !loadLatencies.isEmpty else { return 0 }
        return loadLatencies.reduce(0, +) / Double(loadLatencies.count)
    }

    // MARK: - Formatted Display

    /// 格式化搜索 P95 显示 (精确到2位有效数字)
    var formattedSearchP95: String {
        formatLatency(searchP95)
    }

    /// 格式化首屏加载 P95 显示
    var formattedLoadP95: String {
        formatLatency(loadP95)
    }

    /// 样本数量
    var searchSampleCount: Int {
        searchLatencies.count
    }

    var loadSampleCount: Int {
        loadLatencies.count
    }

    // MARK: - Reset

    /// 重置所有指标
    func reset() {
        searchLatencies.removeAll()
        loadLatencies.removeAll()
    }

    // MARK: - Helpers

    private func calculateP95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = Int(Double(sorted.count) * 0.95)
        return sorted[min(index, sorted.count - 1)]
    }

    private func formatLatency(_ ms: Double) -> String {
        if ms == 0 {
            return "N/A"
        } else if ms < 1 {
            return String(format: "%.2f ms", ms)
        } else if ms < 10 {
            return String(format: "%.1f ms", ms)
        } else {
            return String(format: "%.0f ms", ms)
        }
    }
}

// MARK: - Convenience Methods for Main Actor

extension PerformanceMetrics {
    /// 获取性能摘要 (供 UI 使用)
    func getSummary() async -> PerformanceSummary {
        return PerformanceSummary(
            searchP95: searchP95,
            loadP95: loadP95,
            searchAvg: searchAvg,
            loadAvg: loadAvg,
            searchSamples: searchLatencies.count,
            loadSamples: loadLatencies.count
        )
    }
}

/// 性能摘要数据结构
struct PerformanceSummary: Sendable {
    let searchP95: Double
    let loadP95: Double
    let searchAvg: Double
    let loadAvg: Double
    let searchSamples: Int
    let loadSamples: Int

    /// 格式化搜索 P95 (精确到2位有效数字)
    var formattedSearchP95: String {
        formatLatency(searchP95)
    }

    /// 格式化首屏加载 P95
    var formattedLoadP95: String {
        formatLatency(loadP95)
    }

    private func formatLatency(_ ms: Double) -> String {
        if ms == 0 || searchSamples == 0 {
            return "N/A"
        } else if ms < 1 {
            return String(format: "%.2f ms", ms)
        } else if ms < 10 {
            return String(format: "%.1f ms", ms)
        } else {
            return String(format: "%.0f ms", ms)
        }
    }
}
