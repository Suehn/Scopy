#if SCOPY_SNAPSHOT_PERF_TESTS
import XCTest
import ScopyKit

/// Snapshot-based performance tests.
///
/// Notes:
/// - These tests are *opt-in* and use the repo-local perf snapshot DB (ignored by git).
/// - Prepare snapshot with: `make snapshot-perf-db`
@MainActor
final class SnapshotPerformanceTests: XCTestCase {

    func testEndToEndSearchLatencyOnPerfSnapshot() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dbSource = ProcessInfo.processInfo.environment["SCOPY_SNAPSHOT_DB_PATH"] == nil ? "default" : "env"
        let dbPath = resolveSnapshotDBPath(repoRoot: repoRoot)
        let dbLabel = URL(fileURLWithPath: dbPath).lastPathComponent

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: dbPath),
            "Missing snapshot DB at \(dbPath). Run: `make snapshot-perf-db` (or set SCOPY_SNAPSHOT_DB_PATH)"
        )
        print("📌 Snapshot DB (\(dbSource)): \(dbPath)")

        // Use an isolated settings store to avoid mutating user defaults.
        let suiteName = "Scopy.SnapshotPerfTests.\(UUID().uuidString)"
        let settingsStore = SettingsStore(suiteName: suiteName)
        var settings = SettingsDTO.default
        settings.showImageThumbnails = true
        await settingsStore.save(settings)

        let service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: "ScopySnapshotPerfTests",
            monitorPollingInterval: 60
        )
        try await service.start()

        // Warmup
        _ = try await service.fetchRecent(limit: 50, offset: 0)
        _ = try await service.search(query: SearchRequest(query: "cmd", mode: .fuzzyPlus, limit: 50, offset: 0))

        func measure(query: String, label: String, maxP95: Double) async throws {
            var times: [Double] = []
            let iterations = 30
            times.reserveCapacity(iterations)

            let request = SearchRequest(query: query, mode: .fuzzyPlus, limit: 50, offset: 0)
            // One extra warmup for the measured query to reduce cold-path noise (index build, caches, etc.).
            _ = try await service.search(query: request)

            for _ in 0..<iterations {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await service.search(query: request)
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }

            let p95 = percentile(times, 95)
            let avg = times.reduce(0, +) / Double(times.count)
            print("📊 Snapshot End-to-End Search (\(label)):")
            print("   - Samples: \(times.count)")
            print("   - Average: \(String(format: "%.2f", avg))ms")
            print("   - P95: \(String(format: "%.2f", p95))ms")
            print("   - Target: P95 < \(String(format: "%.2f", maxP95))ms")
            XCTAssertLessThan(p95, maxP95, "\(label) P95 \(p95)ms exceeds \(maxP95)ms target")
        }

        // v0.md 4.1: ≤5k items => P95 ≤ 50ms. Snapshot may be ~6k; keep the target aligned to UX goal.
        try await measure(query: "cmd", label: "\(dbLabel), fuzzyPlus, query=cmd", maxP95: 50)

        // Short query path (≤2 chars) is a common UX hot path and should remain snappy.
        // Note: End-to-end includes service layer overhead (DTO conversion, metadata, etc.). Use a stable default SLO,
        // and allow an optional strict target for profiling sessions.
        let strictShortQuerySLO = ProcessInfo.processInfo.environment["SCOPY_SNAPSHOT_STRICT_SLO"] == "1"
        #if DEBUG
        let defaultCmP95Target = 150.0
        #else
        let defaultCmP95Target = 50.0
        #endif
        let cmP95Target = strictShortQuerySLO ? 15.0 : defaultCmP95Target
        print("📌 Snapshot short-query SLO: strict=\(strictShortQuerySLO ? 1 : 0) targetP95=\(cmP95Target)ms")
        try await measure(query: "cm", label: "\(dbLabel), fuzzyPlus, query=cm", maxP95: cmP95Target)

        await service.stopAndWait()
    }

    func testEndToEndFirstScreenLoadOnPerfSnapshot() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dbPath = resolveSnapshotDBPath(repoRoot: repoRoot)
        let dbLabel = URL(fileURLWithPath: dbPath).lastPathComponent

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: dbPath),
            "Missing snapshot DB at \(dbPath). Run: `make snapshot-perf-db` (or set SCOPY_SNAPSHOT_DB_PATH)"
        )

        let suiteName = "Scopy.SnapshotPerfTests.\(UUID().uuidString)"
        let settingsStore = SettingsStore(suiteName: suiteName)
        var settings = SettingsDTO.default
        settings.showImageThumbnails = true
        await settingsStore.save(settings)

        let service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: "ScopySnapshotPerfTests",
            monitorPollingInterval: 60
        )
        try await service.start()

        // Warmup
        _ = try await service.fetchRecent(limit: 50, offset: 0)

        var times: [Double] = []
        let iterations = 30
        times.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await service.fetchRecent(limit: 50, offset: 0)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let p95 = percentile(times, 95)
        let avg = times.reduce(0, +) / Double(times.count)
        print("📊 Snapshot End-to-End Load (\(dbLabel), fetchRecent 50):")
        print("   - Samples: \(times.count)")
        print("   - Average: \(String(format: "%.2f", avg))ms")
        print("   - P95: \(String(format: "%.2f", p95))ms")

        // v0.md 2.2: first screen 50-100 items < 100ms.
        XCTAssertLessThan(p95, 100, "Snapshot first-screen load P95 \(p95)ms exceeds 100ms target")

        await service.stopAndWait()
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(Int(Double(sorted.count - 1) * (p / 100.0)), sorted.count - 1)
        return sorted[index]
    }

    private func resolveSnapshotDBPath(repoRoot: URL) -> String {
        if let raw = ProcessInfo.processInfo.environment["SCOPY_SNAPSHOT_DB_PATH"],
           !raw.isEmpty {
            if raw.hasPrefix("/") {
                return raw
            }
            return repoRoot.appendingPathComponent(raw).path
        }
        return repoRoot.appendingPathComponent("perf-db/clipboard.db").path
    }
}

#endif
