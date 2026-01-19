import CryptoKit
import XCTest
@testable import ScopyKit

@MainActor
final class FullIndexDiskCacheHardeningTests: XCTestCase {

    func testDiskCacheIsUsedWhenChecksumMatches() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-fullindex-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            for i in 0..<128 {
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

            let search1 = SearchEngineImpl(dbPath: dbPath)
            try await search1.open()
            let paths: (cachePath: String, checksumPath: String)
            do {
                _ = try await search1.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                paths = await search1.debugFullIndexDiskCachePaths()
                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: 2.0)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: 2.0)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                _ = try await search2.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))

                let source2 = await search2.debugFullIndexLastSnapshotSource()
                XCTAssertEqual(source2, "diskCache")
                await search2.close()
            } catch {
                await search2.close()
                throw error
            }

            await storage.close()
        } catch {
            await storage.close()
            throw error
        }
    }

    func testDiskCacheIsIgnoredWhenChecksumMissingOrMismatched() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-fullindex-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            for i in 0..<128 {
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

            let search1 = SearchEngineImpl(dbPath: dbPath)
            try await search1.open()
            let paths: (cachePath: String, checksumPath: String)
            do {
                _ = try await search1.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                paths = await search1.debugFullIndexDiskCachePaths()
                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: 2.0)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: 2.0)

            // 1) Missing checksum: must fall back to DB build.
            try? FileManager.default.removeItem(atPath: paths.checksumPath)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                _ = try await search2.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                let source2 = await search2.debugFullIndexLastSnapshotSource()
                XCTAssertEqual(source2, "database")
                await search2.close()
            } catch {
                await search2.close()
                throw error
            }

            // 2) Corrupt cache payload: checksum mismatch must fall back to DB build.
            // Recreate a valid cache first.
            let search3 = SearchEngineImpl(dbPath: dbPath)
            try await search3.open()
            let paths2: (cachePath: String, checksumPath: String)
            do {
                _ = try await search3.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                paths2 = await search3.debugFullIndexDiskCachePaths()
                await search3.close()
            } catch {
                await search3.close()
                throw error
            }

            try await Self.waitForFile(at: paths2.cachePath, timeoutSeconds: 2.0)
            try await Self.waitForFile(at: paths2.checksumPath, timeoutSeconds: 2.0)

            var data = try Data(contentsOf: URL(fileURLWithPath: paths2.cachePath))
            if !data.isEmpty {
                data[0] ^= 0xFF
                try data.write(to: URL(fileURLWithPath: paths2.cachePath), options: [.atomic])
            }

            let search4 = SearchEngineImpl(dbPath: dbPath)
            try await search4.open()
            do {
                _ = try await search4.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                let source4 = await search4.debugFullIndexLastSnapshotSource()
                XCTAssertEqual(source4, "database")
                await search4.close()
            } catch {
                await search4.close()
                throw error
            }

            await storage.close()
        } catch {
            await storage.close()
            throw error
        }
    }

    func testDiskCacheIsIgnoredWhenPostingsInvalidEvenIfChecksumMatches() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-fullindex-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            for i in 0..<128 {
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

            let search1 = SearchEngineImpl(dbPath: dbPath)
            try await search1.open()
            let paths: (cachePath: String, checksumPath: String)
            do {
                _ = try await search1.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                paths = await search1.debugFullIndexDiskCachePaths()
                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: 2.0)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: 2.0)

            // Corrupt postings but keep checksum consistent: the loader must reject the cache and fall back.
            let cacheURL = URL(fileURLWithPath: paths.cachePath)
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

            // Inject an out-of-bounds slot into a common postings list ('i' in "item").
            let iIndex = Int(Character("i").asciiValue ?? 0)
            asciiPostings[iIndex].append(itemsCount)
            root["asciiCharPostings"] = asciiPostings

            let corruptedData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            try corruptedData.write(to: cacheURL, options: [.atomic])

            let checksum = Self.sha256Hex(corruptedData)
            try checksum.write(toFile: paths.checksumPath, atomically: true, encoding: .utf8)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                _ = try await search2.search(request: SearchRequest(query: "item", mode: .fuzzy, forceFullFuzzy: true, limit: 10, offset: 0))
                let source2 = await search2.debugFullIndexLastSnapshotSource()
                XCTAssertEqual(source2, "database")
                await search2.close()
            } catch {
                await search2.close()
                throw error
            }

            await storage.close()
        } catch {
            await storage.close()
            throw error
        }
    }

    private static func waitForFile(at path: String, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTFail("Timed out waiting for file: \(path)")
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
