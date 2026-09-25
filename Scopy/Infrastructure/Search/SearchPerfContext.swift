import Foundation

/// Collects the phases, counters, and reasons of one search when `SCOPY_PERF_METRICS=1`;
/// ScopyBench reports them through `SearchEngineImpl.SearchPerfMetrics`.
final class SearchPerfContext: @unchecked Sendable {
    static let metricsEnabled: Bool = ProcessInfo.processInfo.environment["SCOPY_PERF_METRICS"] == "1"

    private(set) var phases: [SearchEngineImpl.SearchPerfMetrics.Phase] = []
    private(set) var counters: [SearchEngineImpl.SearchPerfMetrics.Counter] = []
    private(set) var reasons: [SearchEngineImpl.SearchPerfMetrics.Reason] = []

    func addPhase(_ name: String, ms: Double) {
        phases.append(SearchEngineImpl.SearchPerfMetrics.Phase(name: name, ms: ms))
    }

    func addCounter(_ name: String, value: Int) {
        counters.append(SearchEngineImpl.SearchPerfMetrics.Counter(name: name, value: value))
    }

    func addReason(_ name: String) {
        reasons.append(SearchEngineImpl.SearchPerfMetrics.Reason(name: name))
    }

    /// Folds in the background full-index load this search awaited.
    func addFullIndexLoad(_ metrics: SearchWarmLoadMetrics, itemCount: Int) {
        for phase in metrics.phases {
            addPhase(phase.name, ms: phase.ms)
        }
        for counter in metrics.counters {
            addCounter(counter.name, value: counter.value)
        }
        for reason in metrics.reasons {
            addReason(reason)
        }
        let source = metrics.source == .diskCache ? "full_index_source_disk_cache" : "full_index_source_database"
        addCounter(source, value: 1)
        addCounter("full_index_items", value: itemCount)
    }

    func measure<T>(_ name: String, _ block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            addPhase(name, ms: elapsedMs)
        }
        return try block()
    }

    func snapshot() -> SearchEngineImpl.SearchPerfMetrics {
        SearchEngineImpl.SearchPerfMetrics(phases: phases, counters: counters, reasons: reasons)
    }
}
