import CryptoKit
import XCTest
@testable import ScopyKit

@MainActor
final class FullIndexDiskCacheHardeningTests: XCTestCase {
    private typealias DiskCachePaths = (cachePath: String, checksumPath: String, metadataPath: String)

    func testDiskCacheHitReportsDiskCacheReason() async throws {
        try await withSeededDatabase { dbPath, _ in
            _ = try await buildFullIndexDiskCache(dbPath: dbPath)

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "diskCache")
            XCTAssertEqual(result.reason, "disk_cache_hit")
        }
    }

    func testMissingMetadataBootstrapsLegacyCacheWithoutDatabaseRebuild() async throws {
        try await withSeededDatabase { dbPath, _ in
            let paths = try await buildFullIndexDiskCache(dbPath: dbPath)
            try? FileManager.default.removeItem(atPath: paths.metadataPath)

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "diskCache")
            XCTAssertEqual(result.reason, "disk_cache_hit")
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadataPath))
        }
    }

    func testFingerprintMismatchFallsBackBeforePayloadValidation() async throws {
        try await withSeededDatabase { dbPath, storage in
            let paths = try await buildFullIndexDiskCache(dbPath: dbPath)
            try corruptCachePayload(at: paths.cachePath)

            let changedText = "item mutated after cache build"
            let changedContent = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: changedText,
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "hash-mutated-\(UUID().uuidString)",
                sizeBytes: changedText.utf8.count
            )
            _ = try await storage.upsertItem(changedContent)

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "database")
            XCTAssertEqual(result.reason, "fingerprint_mismatch")
        }
    }

    func testSHMDriftDoesNotInvalidateFullIndexDiskCache() async throws {
        try await withSeededDatabase { dbPath, _ in
            let paths = try await buildFullIndexDiskCache(dbPath: dbPath)
            try mutateMetadata(at: paths.metadataPath) { root in
                guard var fingerprint = root["fingerprint"] as? [String: Any] else { return }
                fingerprint["shmModifiedAt"] = (fingerprint["shmModifiedAt"] as? Double ?? 0) + 1234
                fingerprint["shmSize"] = (fingerprint["shmSize"] as? Int ?? 0) + 1
                root["fingerprint"] = fingerprint
            }

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "diskCache")
            XCTAssertEqual(result.reason, "disk_cache_hit")
        }
    }

    func testTombstoneStaleMetadataSkipsPayloadLoad() async throws {
        try await withSeededDatabase { dbPath, _ in
            let paths = try await buildFullIndexDiskCache(dbPath: dbPath)
            try mutateMetadata(at: paths.metadataPath) { root in
                root["itemCount"] = 128
                root["tombstoneCount"] = 48
                root["tombstoneRatio"] = 48.0 / 128.0
            }
            try corruptCachePayload(at: paths.cachePath)

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "database")
            XCTAssertEqual(result.reason, "tombstone_stale")
        }
    }

    func testChecksumMismatchFallsBackToDatabaseWithExplicitReason() async throws {
        try await withSeededDatabase { dbPath, _ in
            let paths = try await buildFullIndexDiskCache(dbPath: dbPath)
            try corruptCachePayload(at: paths.cachePath)

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "database")
            XCTAssertEqual(result.reason, "checksum_mismatch")
        }
    }

    func testInvalidPostingsStillFallBackWithPayloadInvalidReason() async throws {
        try await withSeededDatabase { dbPath, _ in
            let paths = try await buildFullIndexDiskCache(dbPath: dbPath)
            try corruptPostingsKeepingChecksumConsistent(cachePath: paths.cachePath, checksumPath: paths.checksumPath)

            let result = try await runRefineSearch(dbPath: dbPath)
            XCTAssertEqual(result.source, "database")
            XCTAssertEqual(result.reason, "payload_invalid")
        }
    }

    private func withSeededDatabase(
        _ body: (_ dbPath: String, _ storage: StorageService) async throws -> Void
    ) async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-fullindex-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path
        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            try await seedTextCorpus(storage: storage, count: 128)
            try await body(dbPath, storage)
            await storage.close()
        } catch {
            await storage.close()
            throw error
        }
    }

    private func seedTextCorpus(storage: StorageService, count: Int) async throws {
        for i in 0..<count {
            let text = "item \(i)"
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: text,
                payload: .none,
                appBundleID: "com.test.app",
                contentHash: "hash-\(i)-\(UUID().uuidString)",
                sizeBytes: text.utf8.count
            )
            _ = try await storage.upsertItem(content)
        }
    }

    private func buildFullIndexDiskCache(dbPath: String) async throws -> DiskCachePaths {
        let search = SearchEngineImpl(dbPath: dbPath)
        try await search.open()
        let paths: DiskCachePaths
        do {
            _ = try await search.search(
                request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0)
            )
            paths = await search.debugFullIndexDiskCachePaths()
            await search.close()
        } catch {
            await search.close()
            throw error
        }

        try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: 2.0)
        try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: 2.0)
        try await Self.waitForFile(at: paths.metadataPath, timeoutSeconds: 2.0)
        return paths
    }

    private func runRefineSearch(dbPath: String) async throws -> (source: String?, reason: String?) {
        let search = SearchEngineImpl(dbPath: dbPath)
        try await search.open()
        do {
            _ = try await search.search(
                request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0)
            )
            let source = await search.debugFullIndexLastSnapshotSource()
            let reason = await search.debugFullIndexLastDiskCacheLoadReason()
            await search.close()
            return (source, reason)
        } catch {
            await search.close()
            throw error
        }
    }

    private func mutateMetadata(at path: String, mutate: (inout [String: Any]) -> Void) throws {
        let url = URL(fileURLWithPath: path)
        let originalData = try Data(contentsOf: url)
        var format: PropertyListSerialization.PropertyListFormat = .binary
        let any = try PropertyListSerialization.propertyList(from: originalData, options: [], format: &format)
        guard var root = any as? [String: Any] else {
            XCTFail("Unexpected metadata plist root")
            return
        }
        mutate(&root)
        let mutatedData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try mutatedData.write(to: url, options: [.atomic])
    }

    private func corruptCachePayload(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        var data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        data[0] ^= 0xFF
        try data.write(to: url, options: [.atomic])
    }

    private func corruptPostingsKeepingChecksumConsistent(cachePath: String, checksumPath: String) throws {
        let cacheURL = URL(fileURLWithPath: cachePath)
        let originalData = try Data(contentsOf: cacheURL)
        var format: PropertyListSerialization.PropertyListFormat = .binary
        let any = try PropertyListSerialization.propertyList(from: originalData, options: [], format: &format)
        guard var root = any as? [String: Any] else {
            XCTFail("Unexpected plist root")
            return
        }
        guard let items = root["items"] as? [Any] else {
            XCTFail("Missing items")
            return
        }
        let itemsCount = items.count
        guard var asciiPostings = root["asciiCharPostings"] as? [[Int]] else {
            XCTFail("Missing asciiCharPostings")
            return
        }
        XCTAssertEqual(asciiPostings.count, 128)

        let iIndex = Int(Character("i").asciiValue ?? 0)
        asciiPostings[iIndex].append(itemsCount)
        root["asciiCharPostings"] = asciiPostings

        let corruptedData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try corruptedData.write(to: cacheURL, options: [.atomic])

        let checksum = Self.sha256Hex(corruptedData)
        try checksum.write(toFile: checksumPath, atomically: true, encoding: .utf8)
    }

    private static func waitForFile(at path: String, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for file: \(path)")
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
