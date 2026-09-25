import Foundation

struct SearchWarmLoadMetrics: Sendable {
    struct Phase: Sendable {
        let name: String
        let ms: Double
    }

    struct Counter: Sendable {
        let name: String
        let value: Int
    }

    private(set) var phases: [Phase] = []
    private(set) var counters: [Counter] = []
    private(set) var reasons: [String] = []
    private(set) var source: FullIndexSnapshotSource?
    private(set) var usedDiskCache = false

    mutating func measure<T>(_ name: String, _ block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            phases.append(Phase(name: name, ms: elapsedMs))
        }
        return try block()
    }

    mutating func markSource(_ source: FullIndexSnapshotSource) {
        self.source = source
        if source == .diskCache {
            usedDiskCache = true
        }
    }

    mutating func addCounter(_ name: String, value: Int) {
        counters.append(Counter(name: name, value: value))
    }

    mutating func addReason(_ reason: FullIndexDiskCacheLoadReason) {
        reasons.append(reason.rawValue)
    }

    var summary: String {
        var parts = phases.map { "\($0.name)=\(String(format: "%.2f", $0.ms))ms" }
        if !counters.isEmpty {
            parts.append(
                counters
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: ", ")
            )
        }
        if !reasons.isEmpty {
            parts.append("reasons=" + reasons.joined(separator: "|"))
        }
        return parts.joined(separator: ", ")
    }
}
