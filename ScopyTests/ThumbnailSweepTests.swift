import XCTest
@testable import ScopyKit

final class ThumbnailSweepTests: XCTestCase {
    func testFullCleanupRemovesOnlyUnreferencedThumbnails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-thumbnail-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = StorageService(databasePath: directory.appendingPathComponent("clipboard.db").path)
        try await storage.open()

        let deletedImageHash = String(repeating: "a", count: 64)
        let keptImageHash = String(repeating: "b", count: 64)
        let keptFileHash = "file:" + String(repeating: "c", count: 64)
        let deletedImage = try await storage.upsertItem(image(hash: deletedImageHash))
        _ = try await storage.upsertItem(image(hash: keptImageHash))
        _ = try await storage.upsertItem(ClipboardMonitor.ClipboardContent(
            type: .file,
            plainText: "/tmp/kept.txt",
            payload: .none,
            appBundleID: "com.test.app",
            contentHash: keptFileHash,
            sizeBytes: 13
        ))
        try await storage.deleteItem(deletedImage.id)

        let thumbnails = storage.thumbnailCacheDirectoryPath
        try FileManager.default.createDirectory(atPath: thumbnails, withIntermediateDirectories: true)
        let orphanedNames = [
            "\(deletedImageHash).png",
            "file_\(String(repeating: "d", count: 64)).png",
            "file_file:\(String(repeating: "e", count: 64)).png",
        ]
        let keptNames = [
            "\(keptImageHash).png",
            StorageService.fileThumbnailFilename(for: keptFileHash),
            "notes.txt",
            "\(String(repeating: "f", count: 63)).png",
        ]
        for name in orphanedNames + keptNames {
            try Data([0x89]).write(to: URL(fileURLWithPath: thumbnails).appendingPathComponent(name))
        }

        _ = try await storage.performCleanup(mode: .full, policy: StorageService.CleanupPolicy())

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: thumbnails))
        XCTAssertEqual(remaining, Set(keptNames))
        await storage.close()
    }

    private func image(hash: String) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "[Image]",
            payload: .data(Data([0x89, 0x50, 0x4E, 0x47])),
            appBundleID: "com.test.app",
            contentHash: hash,
            sizeBytes: 4
        )
    }
}
