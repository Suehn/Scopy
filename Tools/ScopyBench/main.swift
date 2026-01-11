import Foundation
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
        var dbPath: String
        var mode: SearchMode
        var sortMode: SearchSortMode
        var query: String
        var forceFullFuzzy: Bool
        var limit: Int
        var offset: Int
        var iterations: Int
        var warmup: Int

        static func parse() throws -> Options {
            var dbPath: String?
            var mode: SearchMode = .fuzzyPlus
            var sortMode: SearchSortMode = .relevance
            var query: String?
            var forceFullFuzzy: Bool = false
            var limit: Int = 50
            var offset: Int = 0
            var iterations: Int = 20
            var warmup: Int = 3

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
                case "--db":
                    dbPath = try requireValue("--db")
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
                dbPath: dbPath,
                mode: mode,
                sortMode: sortMode,
                query: query,
                forceFullFuzzy: forceFullFuzzy,
                limit: limit,
                offset: offset,
                iterations: iterations,
                warmup: warmup
            )
        }

        static func helpText() -> String {
            """
            ScopyBench — local search benchmark utility (no content printed).

            Usage:
              swift run ScopyBench --db <path> --query <text> [options]

            Options:
              --mode <exact|fuzzy|fuzzyPlus|regex>   Default: fuzzyPlus
              --sort <relevance|recent>             Default: relevance
              --force-full-fuzzy                    Force full-history fuzzy scan (skip prefilter)
              --limit <n>                            Default: 50
              --offset <n>                           Default: 0
              --iters <n>                            Default: 20
              --warmup <n>                           Default: 3
            """
        }
    }

    static func main() async {
        do {
            let options = try Options.parse()
            let engine = SearchEngineImpl(dbPath: options.dbPath)
            try await engine.open()
            defer { Task { await engine.close() } }

            func runOnce() async throws -> Double {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await engine.search(
                    request: SearchRequest(
                        query: options.query,
                        mode: options.mode,
                        sortMode: options.sortMode,
                        forceFullFuzzy: options.forceFullFuzzy,
                        limit: options.limit,
                        offset: options.offset
                    )
                )
                return (CFAbsoluteTimeGetCurrent() - start) * 1000
            }

            if options.warmup > 0 {
                for _ in 0..<options.warmup {
                    _ = try await runOnce()
                }
            }

            var times: [Double] = []
            times.reserveCapacity(options.iterations)
            for _ in 0..<options.iterations {
                times.append(try await runOnce())
            }

            times.sort()
            let avg = times.reduce(0, +) / Double(times.count)
            let p95Index = min(Int(Double(times.count) * 0.95), times.count - 1)
            let p95 = times[p95Index]

            let forceText = options.forceFullFuzzy ? "1" : "0"
            let requestSummary = "mode=\(options.mode.rawValue) sort=\(options.sortMode.rawValue) forceFullFuzzy=\(forceText) limit=\(options.limit) offset=\(options.offset) queryLen=\(options.query.count)"
            let avgText = String(format: "%.2f", avg)
            let p95Text = String(format: "%.2f", p95)
            print("ScopyBench: \(requestSummary)")
            print("  samples=\(times.count) avg_ms=\(avgText) p95_ms=\(p95Text)")
        } catch {
            fputs("Error: \(error.localizedDescription)\n\n", stderr)
            fputs(Options.helpText() + "\n", stderr)
            exit(1)
        }
    }
}
