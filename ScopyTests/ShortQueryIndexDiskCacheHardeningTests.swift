#if DEBUG
import CryptoKit
import XCTest
@testable import ScopyKit

@MainActor
final class ShortQueryIndexDiskCacheHardeningTests: XCTestCase {

    private static let fileWaitTimeoutSeconds: TimeInterval = 10.0

    func testDiskCacheIsUsedWhenChecksumMatches() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-shortindex-cache-\(UUID().uuidString)")
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
                await search1.debugStartShortQueryIndexBuild(force: true)
                await search1.debugAwaitShortQueryIndexBuild()
                paths = await search1.debugShortQueryIndexDiskCachePaths()
                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                await search2.debugStartShortQueryIndexBuild(force: true)
                await search2.debugAwaitShortQueryIndexBuild()

                let source2 = await search2.debugShortQueryIndexLastSnapshotSource()
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
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-shortindex-cache-\(UUID().uuidString)")
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
                await search1.debugStartShortQueryIndexBuild(force: true)
                await search1.debugAwaitShortQueryIndexBuild()
                paths = await search1.debugShortQueryIndexDiskCachePaths()
                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)

            // 1) Missing checksum: must fall back to DB build.
            try? FileManager.default.removeItem(atPath: paths.checksumPath)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                await search2.debugStartShortQueryIndexBuild(force: true)
                await search2.debugAwaitShortQueryIndexBuild()
                let source2 = await search2.debugShortQueryIndexLastSnapshotSource()
                XCTAssertEqual(source2, "database")
                await search2.close()
            } catch {
                await search2.close()
                throw error
            }

            // 2) Corrupt cache payload: checksum mismatch must fall back to DB build.
            let search3 = SearchEngineImpl(dbPath: dbPath)
            try await search3.open()
            let paths2: (cachePath: String, checksumPath: String)
            do {
                await search3.debugStartShortQueryIndexBuild(force: true)
                await search3.debugAwaitShortQueryIndexBuild()
                paths2 = await search3.debugShortQueryIndexDiskCachePaths()
                await search3.close()
            } catch {
                await search3.close()
                throw error
            }

            try await Self.waitForFile(at: paths2.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
            try await Self.waitForFile(at: paths2.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)

            var data = try Data(contentsOf: URL(fileURLWithPath: paths2.cachePath))
            if !data.isEmpty {
                data[0] ^= 0xFF
                try data.write(to: URL(fileURLWithPath: paths2.cachePath), options: [.atomic])
            }

            let search4 = SearchEngineImpl(dbPath: dbPath)
            try await search4.open()
            do {
                await search4.debugStartShortQueryIndexBuild(force: true)
                await search4.debugAwaitShortQueryIndexBuild()
                let source4 = await search4.debugShortQueryIndexLastSnapshotSource()
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
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-shortindex-cache-\(UUID().uuidString)")
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
                await search1.debugStartShortQueryIndexBuild(force: true)
                await search1.debugAwaitShortQueryIndexBuild()
                paths = await search1.debugShortQueryIndexDiskCachePaths()
                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)

            // Corrupt postings but keep checksum consistent: the loader must reject the cache and fall back.
            let cacheURL = URL(fileURLWithPath: paths.cachePath)
            let originalData = try Data(contentsOf: cacheURL)
            var format: PropertyListSerialization.PropertyListFormat = .binary
            let any = try PropertyListSerialization.propertyList(from: originalData, options: [], format: &format)
            guard var root = any as? [String: Any] else {
                XCTFail("Unexpected plist root")
                return
            }
            guard let slots = root["slots"] as? [Any] else {
                XCTFail("Missing slots")
                return
            }
            let slotsCount = slots.count

            guard var asciiPostings = root["asciiCharPostings"] as? [[Int]] else {
                XCTFail("Missing asciiCharPostings")
                return
            }
            XCTAssertEqual(asciiPostings.count, 128)

            // Inject an out-of-bounds slot into a common postings list ('i' in "item").
            let iIndex = Int(Character("i").asciiValue ?? 0)
            asciiPostings[iIndex].append(slotsCount)
            root["asciiCharPostings"] = asciiPostings

            let corruptedData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            try corruptedData.write(to: cacheURL, options: [.atomic])

            let checksum = Self.sha256Hex(corruptedData)
            try checksum.write(toFile: paths.checksumPath, atomically: true, encoding: .utf8)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                await search2.debugStartShortQueryIndexBuild(force: true)
                await search2.debugAwaitShortQueryIndexBuild()
                let source2 = await search2.debugShortQueryIndexLastSnapshotSource()
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

    func testDiskCacheRemainsUsableAfterUsageUpserts() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-shortindex-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            let contentHash = "hash-stable-\(UUID().uuidString)"
            let plainText = "cmd"
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: plainText,
                payload: .none,
                note: "note-1",
                appBundleID: "com.test.app",
                contentHash: contentHash,
                sizeBytes: plainText.utf8.count
            )

            let inserted = try await storage.upsertItem(content)

            let search1 = SearchEngineImpl(dbPath: dbPath)
            try await search1.open()
            let paths: (cachePath: String, checksumPath: String)
            do {
                await search1.debugStartShortQueryIndexBuild(force: true)
                await search1.debugAwaitShortQueryIndexBuild()
                paths = await search1.debugShortQueryIndexDiskCachePaths()

                // Simulate a common "usage update" path: same contentHash => update lastUsedAt/useCount only.
                var updated = inserted
                updated.lastUsedAt = Date()
                updated.useCount += 1
                await search1.handleUpsertedItem(updated)

                await search1.close()
            } catch {
                await search1.close()
                throw error
            }

            try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
            try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                await search2.debugStartShortQueryIndexBuild(force: true)
                await search2.debugAwaitShortQueryIndexBuild()

                let source2 = await search2.debugShortQueryIndexLastSnapshotSource()
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

    func testDiskCacheRemainsUsableAfterNoteChangeReindex() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-shortindex-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        do {
            let contentHash = "hash-stable-\(UUID().uuidString)"
            let plainText = "cmd"
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: plainText,
                payload: .none,
                note: "note-1",
                appBundleID: "com.test.app",
                contentHash: contentHash,
                sizeBytes: plainText.utf8.count
            )

            let inserted = try await storage.upsertItem(content)

            let search1 = SearchEngineImpl(dbPath: dbPath)
            try await search1.open()
            let paths: (cachePath: String, checksumPath: String)
            do {
                await search1.debugStartShortQueryIndexBuild(force: true)
                await search1.debugAwaitShortQueryIndexBuild()
                paths = await search1.debugShortQueryIndexDiskCachePaths()

                // Ensure the initial DB-built disk cache persist has completed before we mutate the in-memory index.
                try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
                try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)

                // Close and reopen so that:
                // 1) there is no in-flight persist task from the initial DB snapshot
                // 2) we start from the on-disk cache and verify it loads
                await search1.close()
                try await search1.open()
                await search1.debugStartShortQueryIndexBuild(force: true)
                await search1.debugAwaitShortQueryIndexBuild()
                let warmSource = await search1.debugShortQueryIndexLastSnapshotSource()
                XCTAssertEqual(warmSource, "diskCache")

                let updated = ClipboardStoredItem(
                    id: inserted.id,
                    type: inserted.type,
                    contentHash: inserted.contentHash,
                    plainText: inserted.plainText,
                    note: "note-2",
                    appBundleID: inserted.appBundleID,
                    createdAt: inserted.createdAt,
                    lastUsedAt: Date(),
                    useCount: inserted.useCount,
                    isPinned: inserted.isPinned,
                    sizeBytes: inserted.sizeBytes,
                    fileSizeBytes: inserted.fileSizeBytes,
                    storageRef: inserted.storageRef,
                    rawData: inserted.rawData
                )
                await search1.handleUpsertedItem(updated)

                let stats1 = await search1.debugShortQueryIndexStats()
                XCTAssertEqual(stats1.live, 1)
                XCTAssertEqual(stats1.tombstones, 1)

                let cacheModifiedBefore = Self.fileModifiedAt(path: paths.cachePath) ?? .distantPast
                let checksumModifiedBefore = Self.fileModifiedAt(path: paths.checksumPath) ?? .distantPast
                await search1.close()

                try await Self.waitForFile(at: paths.cachePath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
                try await Self.waitForFile(at: paths.checksumPath, timeoutSeconds: Self.fileWaitTimeoutSeconds)
                try await Self.waitForFileModification(
                    at: paths.cachePath,
                    after: cacheModifiedBefore,
                    timeoutSeconds: Self.fileWaitTimeoutSeconds
                )
                try await Self.waitForFileModification(
                    at: paths.checksumPath,
                    after: checksumModifiedBefore,
                    timeoutSeconds: Self.fileWaitTimeoutSeconds
                )
            } catch {
                await search1.close()
                throw error
            }

            let search2 = SearchEngineImpl(dbPath: dbPath)
            try await search2.open()
            do {
                await search2.debugStartShortQueryIndexBuild(force: true)
                await search2.debugAwaitShortQueryIndexBuild()

                let source2 = await search2.debugShortQueryIndexLastSnapshotSource()
                XCTAssertEqual(source2, "diskCache")

                let stats2 = await search2.debugShortQueryIndexStats()
                XCTAssertEqual(stats2.live, 1)
                XCTAssertEqual(stats2.tombstones, 1)

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

    private struct WaitForFileError: Error {}

    private static func fileModifiedAt(path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modifiedAt
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
        throw WaitForFileError()
    }

    private static func waitForFileModification(at path: String, after: Date, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let modifiedAt = fileModifiedAt(path: path), modifiedAt > after {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        XCTFail("Timed out waiting for file modification: \(path)")
        throw WaitForFileError()
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
