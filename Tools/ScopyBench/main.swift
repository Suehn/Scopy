import Foundation
import SQLite3
import ScopyKit

@main
enum ScopyBench {
    private enum BenchError: Error, LocalizedError {
        case missingArgument(String)
        case invalidArgument(String)

        var errorDescription: String? {
            switch self {
            case .missingArgument(let name):
                return "Missing required argument: \(name)"
            case .invalidArgument(let message):
                return message
            }
        }
    }

    private struct Options {
        enum Layer: String {
            case engine
            case service
        }

        var layer: Layer
        var dbPath: String
        var label: String?
        var mode: SearchMode
        var sortMode: SearchSortMode
        var query: String
        var forceFullFuzzy: Bool
        var limit: Int
        var offset: Int
        var iterations: Int
        var warmup: Int
        var json: Bool
        var showThumbnails: Bool

        static func parse() throws -> Options {
            var layer: Layer = .engine
            var dbPath: String?
            var label: String?
            var mode: SearchMode = .fuzzyPlus
            var sortMode: SearchSortMode = .relevance
            var query: String?
            var forceFullFuzzy: Bool = false
            var limit: Int = 50
            var offset: Int = 0
            var iterations: Int = 20
            var warmup: Int = 3
            var json: Bool = false
            var showThumbnails: Bool = true

            var args = CommandLine.arguments.dropFirst()
            while let token = args.first {
                args = args.dropFirst()

                func requireValue(_ name: String) throws -> String {
                    guard let value = args.first else {
                        throw BenchError.missingArgument(name)
                    }
                    args = args.dropFirst()
                    return value
                }

                switch token {
                case "--layer":
                    let raw = try requireValue("--layer")
                    guard let parsed = Layer(rawValue: raw) else {
                        throw BenchError.invalidArgument("Invalid --layer: \(raw)")
                    }
                    layer = parsed
                case "--db":
                    dbPath = try requireValue("--db")
                case "--label":
                    label = try requireValue("--label")
                case "--mode":
                    let raw = try requireValue("--mode")
                    guard let parsed = SearchMode(rawValue: raw) else {
                        throw BenchError.invalidArgument("Invalid --mode: \(raw)")
                    }
                    mode = parsed
                case "--sort":
                    let raw = try requireValue("--sort")
                    guard let parsed = SearchSortMode(rawValue: raw) else {
                        throw BenchError.invalidArgument("Invalid --sort: \(raw)")
                    }
                    sortMode = parsed
                case "--query":
                    query = try requireValue("--query")
                case "--force-full-fuzzy":
                    forceFullFuzzy = true
                case "--limit":
                    let raw = try requireValue("--limit")
                    guard let parsed = Int(raw), parsed > 0 else {
                        throw BenchError.invalidArgument("Invalid --limit: \(raw)")
                    }
                    limit = parsed
                case "--offset":
                    let raw = try requireValue("--offset")
                    guard let parsed = Int(raw), parsed >= 0 else {
                        throw BenchError.invalidArgument("Invalid --offset: \(raw)")
                    }
                    offset = parsed
                case "--iters":
                    let raw = try requireValue("--iters")
                    guard let parsed = Int(raw), parsed > 0 else {
                        throw BenchError.invalidArgument("Invalid --iters: \(raw)")
                    }
                    iterations = parsed
                case "--warmup":
                    let raw = try requireValue("--warmup")
                    guard let parsed = Int(raw), parsed >= 0 else {
                        throw BenchError.invalidArgument("Invalid --warmup: \(raw)")
                    }
                    warmup = parsed
                case "--json":
                    json = true
                case "--no-thumbnails":
                    showThumbnails = false
                case "--help", "-h":
                    print(Self.helpText())
                    exit(0)
                default:
                    throw BenchError.invalidArgument("Unknown argument: \(token)")
                }
            }

            guard let dbPath, !dbPath.isEmpty else {
                throw BenchError.missingArgument("--db")
            }
            guard let query else {
                throw BenchError.missingArgument("--query")
            }

            return Options(
                layer: layer,
                dbPath: dbPath,
                label: label,
                mode: mode,
                sortMode: sortMode,
                query: query,
                forceFullFuzzy: forceFullFuzzy,
                limit: limit,
                offset: offset,
                iterations: iterations,
                warmup: warmup,
                json: json,
                showThumbnails: showThumbnails
            )
        }

        static func helpText() -> String {
            """
            ScopyBench — local search benchmark utility (no content printed).

            Usage:
              swift run ScopyBench --db <path> --query <text> [options]

            Options:
              --layer <engine|service>               Default: engine
              --label <text>                        Optional label (not used for search)
              --mode <exact|fuzzy|fuzzyPlus|regex>   Default: fuzzyPlus
              --sort <relevance|recent>             Default: relevance
              --force-full-fuzzy                    Force full-history fuzzy scan (skip prefilter)
              --limit <n>                            Default: 50
              --offset <n>                           Default: 0
              --iters <n>                            Default: 20
              --warmup <n>                           Default: 3
              --json                                Output a single JSON line (no query text included)
              --no-thumbnails                        (service layer only) Disable thumbnail scheduling + thumbnailPath
            """
        }
    }

    private static func fileSizeBytes(at path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func countClipboardItems(dbPath: String) -> Int? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM clipboard_items", -1, &stmt, nil) == SQLITE_OK else {
            if let stmt { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func main() async {
        do {
            let options = try Options.parse()
            switch options.layer {
            case .engine:
                let engine = SearchEngineImpl(dbPath: options.dbPath)
                try await engine.open()
                defer { Task { await engine.close() } }

                func runOnce() async throws -> (elapsedMs: Double, perf: SearchEngineImpl.SearchPerfMetrics?) {
                    let start = CFAbsoluteTimeGetCurrent()
                    let result = try await engine.search(
                        request: SearchRequest(
                            query: options.query,
                            mode: options.mode,
                            sortMode: options.sortMode,
                            forceFullFuzzy: options.forceFullFuzzy,
                            limit: options.limit,
                            offset: options.offset
                        )
                    )
                    return ((CFAbsoluteTimeGetCurrent() - start) * 1000, result.perf)
                }

                if options.warmup > 0 {
                    for _ in 0..<options.warmup {
                        _ = try await runOnce()
                    }
                }

                var times: [Double] = []
                times.reserveCapacity(options.iterations)
                var perfSample: SearchEngineImpl.SearchPerfMetrics?
                for _ in 0..<options.iterations {
                    let (elapsedMs, perf) = try await runOnce()
                    times.append(elapsedMs)
                    if perfSample == nil, let perf {
                        perfSample = perf
                    }
                }

                times.sort()
                let avg = times.reduce(0, +) / Double(times.count)
                let minMs = times.first ?? 0
                let maxMs = times.last ?? 0
                let medianMs = times[times.count / 2]
                let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
                let p95 = times[p95Index]
                let p99Index = min(Int(Double(times.count) * 0.99), times.count - 1)
                let p99 = times[p99Index]

                let forceText = options.forceFullFuzzy ? "1" : "0"
                let requestSummary = "layer=engine mode=\(options.mode.rawValue) sort=\(options.sortMode.rawValue) forceFullFuzzy=\(forceText) limit=\(options.limit) offset=\(options.offset) queryLen=\(options.query.count)"
                if options.json {
                    var payload: [String: Any] = [
                        "tool": "ScopyBench",
                        "schema_version": 1,
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "layer": options.layer.rawValue,
                        "request": [
                            "mode": options.mode.rawValue,
                            "sort": options.sortMode.rawValue,
                            "forceFullFuzzy": options.forceFullFuzzy,
                            "limit": options.limit,
                            "offset": options.offset,
                            "queryLen": options.query.count
                        ],
                        "samples": times.count,
                        "min_ms": minMs,
                        "max_ms": maxMs,
                        "median_ms": medianMs,
                        "avg_ms": avg,
                        "p95_ms": p95,
                        "p99_ms": p99
                    ]

                    if let label = options.label, !label.isEmpty {
                        payload["label"] = label
                    }
                    if let bytes = fileSizeBytes(at: options.dbPath) {
                        payload["db_bytes"] = bytes
                    }
                    if let count = countClipboardItems(dbPath: options.dbPath) {
                        payload["db_item_count"] = count
                    }
                    if let perf = perfSample {
                        payload["perf"] = [
                            "phases": perf.phases.map { ["name": $0.name, "ms": $0.ms] },
                            "counters": perf.counters.map { ["name": $0.name, "value": $0.value] }
                        ]
                    }

                    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
                    if let text = String(data: data, encoding: .utf8) {
                        print(text)
                    }
                    return
                }

                let avgText = String(format: "%.2f", avg)
                let p95Text = String(format: "%.2f", p95)
                let p99Text = String(format: "%.2f", p99)
                let minText = String(format: "%.2f", minMs)
                let maxText = String(format: "%.2f", maxMs)
                let medianText = String(format: "%.2f", medianMs)

                if let label = options.label, !label.isEmpty {
                    print("ScopyBench: [\(label)] \(requestSummary)")
                } else {
                    print("ScopyBench: \(requestSummary)")
                }

                if let bytes = fileSizeBytes(at: options.dbPath), let count = countClipboardItems(dbPath: options.dbPath) {
                    print("  db_bytes=\(bytes) db_item_count=\(count)")
                }
                print(
                    "  samples=\(times.count) min_ms=\(minText) max_ms=\(maxText) " +
                        "median_ms=\(medianText) avg_ms=\(avgText) p95_ms=\(p95Text) p99_ms=\(p99Text)"
                )

            case .service:
                try await runClipboardServiceBench(options: options)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n\n", stderr)
            fputs(Options.helpText() + "\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func runClipboardServiceBench(options: Options) async throws {
        let suiteName = "ScopyBench.\(UUID().uuidString)"
        let settingsStore = SettingsStore(suiteName: suiteName)
        var settings = SettingsDTO.default
        settings.showImageThumbnails = options.showThumbnails
        await settingsStore.save(settings)

        let service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: options.dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: "ScopyBench",
            monitorPollingInterval: 60
        )

        var didStop = false
        defer {
            if !didStop {
                Task { @MainActor in
                    await service.stopAndWait()
                }
            }
        }

        try await service.start()

        // Prime repository + index paths.
        _ = try await service.fetchRecent(limit: min(options.limit, 50), offset: 0)

        func runOnce() async throws -> (elapsedMs: Double, result: SearchResultPage) {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await service.search(
                query: SearchRequest(
                    query: options.query,
                    mode: options.mode,
                    sortMode: options.sortMode,
                    forceFullFuzzy: options.forceFullFuzzy,
                    limit: options.limit,
                    offset: options.offset
                )
            )
            return ((CFAbsoluteTimeGetCurrent() - start) * 1000, result)
        }

        if options.warmup > 0 {
            for _ in 0..<options.warmup {
                _ = try await runOnce()
            }
        }

        var times: [Double] = []
        times.reserveCapacity(options.iterations)
        var typeCounts: [String: Int] = [:]
        var thumbnailHits = 0
        var sampleResultCount: Int?
        for i in 0..<options.iterations {
            let (elapsedMs, result) = try await runOnce()
            times.append(elapsedMs)

            if i == 0 {
                sampleResultCount = result.items.count
                for item in result.items {
                    typeCounts[item.type.rawValue, default: 0] += 1
                    if item.thumbnailPath != nil {
                        thumbnailHits += 1
                    }
                }
            }
        }

        times.sort()
        let avg = times.reduce(0, +) / Double(times.count)
        let minMs = times.first ?? 0
        let maxMs = times.last ?? 0
        let medianMs = times[times.count / 2]
        let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
        let p95 = times[p95Index]
        let p99Index = min(Int(Double(times.count) * 0.99), times.count - 1)
        let p99 = times[p99Index]

        let forceText = options.forceFullFuzzy ? "1" : "0"
        let thumbText = options.showThumbnails ? "1" : "0"
            let requestSummary = "layer=service mode=\(options.mode.rawValue) sort=\(options.sortMode.rawValue) forceFullFuzzy=\(forceText) showThumbnails=\(thumbText) limit=\(options.limit) offset=\(options.offset) queryLen=\(options.query.count)"
        if options.json {
            var payload: [String: Any] = [
                "tool": "ScopyBench",
                "schema_version": 1,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "layer": options.layer.rawValue,
                "request": [
                    "mode": options.mode.rawValue,
                    "sort": options.sortMode.rawValue,
                    "forceFullFuzzy": options.forceFullFuzzy,
                    "limit": options.limit,
                    "offset": options.offset,
                    "queryLen": options.query.count,
                    "showThumbnails": options.showThumbnails
                ],
                "samples": times.count,
                "min_ms": minMs,
                "max_ms": maxMs,
                "median_ms": medianMs,
                "avg_ms": avg,
                "p95_ms": p95,
                "p99_ms": p99
            ]

            if let label = options.label, !label.isEmpty {
                payload["label"] = label
            }
            if let bytes = fileSizeBytes(at: options.dbPath) {
                payload["db_bytes"] = bytes
            }
            if let count = countClipboardItems(dbPath: options.dbPath) {
                payload["db_item_count"] = count
            }
            if let sampleResultCount {
                payload["result_item_count"] = sampleResultCount
                payload["result_thumbnail_hits"] = thumbnailHits
            }
            if !typeCounts.isEmpty {
                payload["result_type_counts"] = typeCounts
            }

            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            let avgText = String(format: "%.2f", avg)
            let p95Text = String(format: "%.2f", p95)
            let p99Text = String(format: "%.2f", p99)
            let minText = String(format: "%.2f", minMs)
            let maxText = String(format: "%.2f", maxMs)
            let medianText = String(format: "%.2f", medianMs)

            if let label = options.label, !label.isEmpty {
                print("ScopyBench: [\(label)] \(requestSummary)")
            } else {
                print("ScopyBench: \(requestSummary)")
            }

            if let bytes = fileSizeBytes(at: options.dbPath), let count = countClipboardItems(dbPath: options.dbPath) {
                print("  db_bytes=\(bytes) db_item_count=\(count)")
            }
            if let sampleResultCount, !typeCounts.isEmpty {
                print("  result_items=\(sampleResultCount) type_counts=\(typeCounts) thumbnail_hits=\(thumbnailHits)")
            }
            print(
                "  samples=\(times.count) min_ms=\(minText) max_ms=\(maxText) " +
                    "median_ms=\(medianText) avg_ms=\(avgText) p95_ms=\(p95Text) p99_ms=\(p99Text)"
            )
        }

        didStop = true
        await service.stopAndWait()
    }
}
