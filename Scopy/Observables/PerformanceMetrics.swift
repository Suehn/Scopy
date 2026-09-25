import Foundation

/// Search and first-load latency samples for the About page diagnostics.
public actor PerformanceMetrics {
    public static let shared = PerformanceMetrics()

    // MARK: - Properties

    private var searchLatencies: [Double] = []
    private var loadLatencies: [Double] = []
    private let maxSamples = 100

    // MARK: - Recording

    /// Records one search latency in milliseconds.
    public func recordSearchLatency(_ ms: Double) {
        recordLatency(ms, buffer: &searchLatencies)
    }

    /// Records one first-page load latency in milliseconds.
    public func recordLoadLatency(_ ms: Double) {
        recordLatency(ms, buffer: &loadLatencies)
    }

    // MARK: - Statistics

    /// Search latency P95 in milliseconds.
    public var searchP95: Double {
        calculateP95(searchLatencies)
    }

    /// First-page load P95 in milliseconds.
    public var loadP95: Double {
        calculateP95(loadLatencies)
    }

    /// Mean search latency in milliseconds.
    public var searchAvg: Double {
        guard !searchLatencies.isEmpty else { return 0 }
        return searchLatencies.reduce(0, +) / Double(searchLatencies.count)
    }

    /// Mean first-page load latency in milliseconds.
    public var loadAvg: Double {
        guard !loadLatencies.isEmpty else { return 0 }
        return loadLatencies.reduce(0, +) / Double(loadLatencies.count)
    }

    // MARK: - Formatted Display

    /// Search P95 for display, two significant digits.
    public var formattedSearchP95: String {
        LatencyFormatter.format(ms: searchP95, samples: nil)
    }

    /// First-page load P95 for display.
    public var formattedLoadP95: String {
        LatencyFormatter.format(ms: loadP95, samples: nil)
    }

    // MARK: - Reset

    /// Clears every sample.
    public func reset() {
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

    private func recordLatency(_ ms: Double, buffer: inout [Double]) {
        buffer.append(ms)
        if buffer.count > maxSamples {
            buffer.removeFirst()
        }
    }
}

// MARK: - Convenience Methods for Main Actor

extension PerformanceMetrics {
    /// A snapshot for the UI.
    public func getSummary() async -> PerformanceSummary {
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

/// Latency snapshot shown on the About page.
public struct PerformanceSummary: Sendable {
    public let searchP95: Double
    public let loadP95: Double
    public let searchAvg: Double
    public let loadAvg: Double
    public let searchSamples: Int
    public let loadSamples: Int

    /// Search P95 for display, two significant digits.
    public var formattedSearchP95: String {
        LatencyFormatter.format(ms: searchP95, samples: searchSamples)
    }

    /// First-page load P95 for display.
    public var formattedLoadP95: String {
        LatencyFormatter.format(ms: loadP95, samples: loadSamples)
    }

    /// Mean search latency for display.
    public var formattedSearchAvg: String {
        LatencyFormatter.format(ms: searchAvg, samples: searchSamples)
    }

    /// Mean first-page load latency for display.
    public var formattedLoadAvg: String {
        LatencyFormatter.format(ms: loadAvg, samples: loadSamples)
    }
}

private enum LatencyFormatter {
    static func format(ms: Double, samples: Int?) -> String {
        if let samples, samples == 0 {
            return "N/A"
        }
        if samples == nil, ms == 0 {
            return "N/A"
        }
        if ms < 1 {
            return String(format: "%.2f ms", ms)
        }
        if ms < 10 {
            return String(format: "%.1f ms", ms)
        }
        return String(format: "%.0f ms", ms)
    }
}
