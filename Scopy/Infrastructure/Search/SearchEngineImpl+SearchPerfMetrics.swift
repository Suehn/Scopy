import Foundation

/// Per-search phases, counters, and reasons, reported when `SCOPY_PERF_METRICS=1`.
extension SearchEngineImpl {
    public struct SearchPerfMetrics: Sendable {
        public struct Phase: Sendable {
            public let name: String
            public let ms: Double

            public init(name: String, ms: Double) {
                self.name = name
                self.ms = ms
            }
        }

        public struct Counter: Sendable {
            public let name: String
            public let value: Int

            public init(name: String, value: Int) {
                self.name = name
                self.value = value
            }
        }

        public struct Reason: Sendable {
            public let name: String

            public init(name: String) {
                self.name = name
            }
        }

        public let phases: [Phase]
        public let counters: [Counter]
        public let reasons: [Reason]

        public init(phases: [Phase], counters: [Counter], reasons: [Reason] = []) {
            self.phases = phases
            self.counters = counters
            self.reasons = reasons
        }
    }
}
