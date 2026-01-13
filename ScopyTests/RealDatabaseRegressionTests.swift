#if SCOPY_REAL_DB_TESTS
import XCTest
@testable import ScopyKit

/// 使用本机真实数据库做的“对照回归”验证（可选）。
///
/// 启用方式：
/// - `swift test -D SCOPY_REAL_DB_TESTS`
/// - 或通过 Xcode scheme 增加 Swift Active Compilation Conditions
///
/// 默认 DB 路径：
/// - `~/Library/Application Support/Scopy/clipboard.db`
///
/// 可通过环境变量覆盖：
/// - `SCOPY_REAL_DB_PATH=/path/to/clipboard.db`
@MainActor
final class RealDatabaseRegressionTests: XCTestCase {

    func testColdStartPrefilterWarmsFullIndexAndRefineMatchesOnDemandResults() async throws {
        let dbPath: String = {
            if let fromEnv = ProcessInfo.processInfo.environment["SCOPY_REAL_DB_PATH"],
               !fromEnv.isEmpty {
                return (fromEnv as NSString).expandingTildeInPath
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Application Support/Scopy/clipboard.db"
        }()

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: dbPath),
            "Missing real DB at: \(dbPath). Set SCOPY_REAL_DB_PATH or create the default file."
        )

        // 选用 fuzzy 模式，确保 refine（forceFullFuzzy=true）会走 fullIndex。
        let query = "abc"
        let requestPrefilter = SearchRequest(query: query, mode: .fuzzy, sortMode: .relevance, limit: 50, offset: 0)
        let requestRefine = SearchRequest(query: query, mode: .fuzzy, sortMode: .relevance, forceFullFuzzy: true, limit: 200, offset: 0)

        // Engine A: 先走一次非 force 的搜索，触发后台预热；等待预热完成，再跑 refine。
        let engineA = SearchEngineImpl(dbPath: dbPath)
        try await engineA.open()
        defer { Task { await engineA.close() } }

        let prefilterA = try await engineA.search(request: requestPrefilter)
        print("[real-db] prefilter searchTimeMs:", prefilterA.searchTimeMs, "isPrefilter:", prefilterA.isPrefilter)
        #if DEBUG
        await engineA.debugAwaitFullIndexBuild()
        #else
        // 在非 DEBUG 构建下没有 debugAwaitFullIndexBuild，保守等待一小段时间让后台预热完成。
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #endif

        let refinedA = try await engineA.search(request: requestRefine)
        print("[real-db] prefilter+prewarm refine searchTimeMs:", refinedA.searchTimeMs)
        let idsA = refinedA.items.map(\.id)

        // Engine B: 冷启动直接跑 refine（会同步构建 fullIndex），作为对照。
        let engineB = SearchEngineImpl(dbPath: dbPath)
        try await engineB.open()
        defer { Task { await engineB.close() } }

        let refinedB = try await engineB.search(request: requestRefine)
        print("[real-db] cold refine (no prewarm) searchTimeMs:", refinedB.searchTimeMs)
        let idsB = refinedB.items.map(\.id)

        XCTAssertEqual(idsA, idsB, "Prefilter+prewarm path must not change refine result ordering")
        XCTAssertFalse(refinedA.isPrefilter)
        XCTAssertFalse(refinedB.isPrefilter)
    }

    func testFullIndexDiskCacheLoadsAndMatchesRebuild() async throws {
        let dbPath: String = {
            if let fromEnv = ProcessInfo.processInfo.environment["SCOPY_REAL_DB_PATH"],
               !fromEnv.isEmpty {
                return (fromEnv as NSString).expandingTildeInPath
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Application Support/Scopy/clipboard.db"
        }()

        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: dbPath),
            "Missing real DB at: \(dbPath). Set SCOPY_REAL_DB_PATH or create the default file."
        )

        let cachePath = "\(dbPath).fullindex.v2.plist"
        if FileManager.default.fileExists(atPath: cachePath) {
            try? FileManager.default.removeItem(atPath: cachePath)
        }

        let requestRefine = SearchRequest(query: "abc", mode: .fuzzy, sortMode: .relevance, forceFullFuzzy: true, limit: 200, offset: 0)

        let engineA = SearchEngineImpl(dbPath: dbPath)
        try await engineA.open()
        let refinedA = try await engineA.search(request: requestRefine)
        print("[real-db] rebuild refine searchTimeMs:", refinedA.searchTimeMs)
        let idsA = refinedA.items.map(\.id)
        await engineA.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath), "Expected fullIndex cache at: \(cachePath)")

        let engineB = SearchEngineImpl(dbPath: dbPath)
        try await engineB.open()
        let refinedB = try await engineB.search(request: requestRefine)
        print("[real-db] disk cache refine searchTimeMs:", refinedB.searchTimeMs)
        let idsB = refinedB.items.map(\.id)

#if DEBUG
        let source = await engineB.debugFullIndexLastSnapshotSource()
        XCTAssertEqual(source, "diskCache")
#endif

        XCTAssertEqual(idsA, idsB, "Disk cache load must not change refine result ordering")

        await engineB.close()
    }
}
#endif
