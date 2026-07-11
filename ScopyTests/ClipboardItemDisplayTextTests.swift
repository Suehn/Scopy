import Foundation
import XCTest
import ScopyKit

@testable import Scopy

final class ClipboardItemDisplayTextTests: XCTestCase {
    @MainActor
    func testTextMetadataMatchesLegacyImplementation() {
        let samples: [String] = [
            "",
            "hello world",
            "你好 世界",
            "a\nb",
            "a\r\nb",
            "\n\n",
            "line1\u{2028}line2",
            "123456789012345",
            "1234567890123456",
            "ends-with-cr\r",
            "ends-with-lf\n",
            "emoji🙂test\nnext"
        ]

        for text in samples {
            let expected = legacyTextMetadata(text)
            let actual = ClipboardItemDisplayText.shared.metadata(for: makeTextItem(plainText: text))
            XCTAssertEqual(actual, expected, "metadata mismatch for text: \(String(reflecting: text))")
        }
    }

    @MainActor
    func testFileTitleAndMetadataMatchLegacyImplementation() {
        let fiveGiB = 5 * 1024 * 1024 * 1024
        let samples: [(plainText: String, note: String?, fileSizeBytes: Int?)] = [
            ("/tmp/a.txt", nil, nil),
            ("/tmp/a.txt", "hello", nil),
            ("/tmp/a.txt", nil, 0),
            ("/tmp/a.txt", nil, 123),
            ("/tmp/five-gib.dat", nil, fiveGiB),
            ("/tmp/a.txt\n/tmp/b.txt", nil, nil),
            ("/tmp/a.txt\n/tmp/b.txt", "note", 1024),
            ("\n/tmp/a.txt\n\n/tmp/b.txt\n", nil, 2048)
        ]

        for sample in samples {
            let item = makeFileItem(
                plainText: sample.plainText,
                note: sample.note,
                fileSizeBytes: sample.fileSizeBytes
            )

            let expectedTitle = legacyFileTitle(sample.plainText)
            let expectedMetadata = legacyFileMetadata(sample.plainText, note: sample.note, fileSizeBytes: sample.fileSizeBytes)

            let actualTitle = ClipboardItemDisplayText.shared.title(for: item)
            let actualMetadata = ClipboardItemDisplayText.shared.metadata(for: item)

            XCTAssertEqual(actualTitle, expectedTitle, "title mismatch for file plainText: \(String(reflecting: sample.plainText))")
            XCTAssertEqual(actualMetadata, expectedMetadata, "metadata mismatch for file plainText: \(String(reflecting: sample.plainText))")
            if sample.fileSizeBytes == fiveGiB {
                XCTAssertEqual(actualMetadata, "5120.0 MB")
            }
        }
    }

    @MainActor
    func testDisplayTextsCachesTitleAndMetadataTogether() {
        let item = makeFileItem(plainText: "/tmp/a.txt\n/tmp/b.txt", note: "note", fileSizeBytes: 1024)
        ClipboardItemDisplayText.shared.clearCaches()

        let pair = ClipboardItemDisplayText.shared.displayTexts(for: item)

        XCTAssertEqual(pair.title, legacyFileTitle(item.plainText))
        XCTAssertEqual(pair.metadata, legacyFileMetadata(item.plainText, note: item.note, fileSizeBytes: item.fileSizeBytes))
        XCTAssertEqual(ClipboardItemDisplayText.shared.cachedTitle(for: item), pair.title)
        XCTAssertEqual(ClipboardItemDisplayText.shared.cachedMetadata(for: item), pair.metadata)
    }

    @MainActor
    func testPrewarmCachesTitleAndMetadata() async {
        let item = makeTextItem(plainText: "hello world")
        ClipboardItemDisplayText.shared.clearCaches()

        XCTAssertNil(ClipboardItemDisplayText.shared.cachedTitle(for: item))
        XCTAssertNil(ClipboardItemDisplayText.shared.cachedMetadata(for: item))

        let task = ClipboardItemDisplayText.shared.prewarm(items: [item])
        await task?.value

        let cachedTitle = ClipboardItemDisplayText.shared.cachedTitle(for: item)
        let cachedMetadata = ClipboardItemDisplayText.shared.cachedMetadata(for: item)

        XCTAssertEqual(cachedTitle, ClipboardItemDisplayText.shared.title(for: item))
        XCTAssertEqual(cachedMetadata, ClipboardItemDisplayText.shared.metadata(for: item))
    }

    @MainActor
    func testDisplayCacheSeparatesSameIDMissingHashEqualLengthContent() {
        let itemID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let first = makeTextItem(id: itemID, contentHash: "", plainText: "AB")
        let replacement = makeTextItem(id: itemID, contentHash: "", plainText: "CD")
        ClipboardItemDisplayText.shared.clearCaches()

        XCTAssertEqual(ClipboardItemDisplayText.shared.title(for: first), "AB")
        XCTAssertNil(ClipboardItemDisplayText.shared.cachedTitle(for: replacement))
        XCTAssertEqual(ClipboardItemDisplayText.shared.title(for: replacement), "CD")
    }

    @MainActor
    func testDisplayCachesEvictOldestRevisionAndAdmitReplacementAtExactCapacity() {
        let cache = ClipboardItemDisplayText.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let replacedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let first = makeTextItem(id: replacedID, contentHash: "", plainText: "first")
        let second = makeTextItem(plainText: "second")
        let replacement = makeTextItem(id: replacedID, contentHash: "", plainText: "replacement")

        _ = cache.displayTexts(for: first)
        _ = cache.displayTexts(for: second)
        XCTAssertEqual(cache.cacheEntryCountsForTesting.title, 2)
        XCTAssertEqual(cache.cacheEntryCountsForTesting.metadata, 2)

        _ = cache.displayTexts(for: replacement)

        XCTAssertNil(cache.cachedTitle(for: first))
        XCTAssertNil(cache.cachedMetadata(for: first))
        XCTAssertEqual(cache.cachedTitle(for: second), "second")
        XCTAssertEqual(cache.cachedTitle(for: replacement), "replacement")
        XCTAssertEqual(cache.cacheEntryCountsForTesting.title, 2)
        XCTAssertEqual(cache.cacheEntryCountsForTesting.metadata, 2)
    }

    @MainActor
    func testDisplayPrewarmCoalescesRapidSupersessionAndCleansBookkeeping() async {
        let cache = ClipboardItemDisplayText.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let staleItems = [
            makeTextItem(plainText: "stale-one"),
            makeTextItem(plainText: "stale-two")
        ]
        let latestItems = [
            makeTextItem(plainText: "latest-one"),
            makeTextItem(plainText: "latest-two")
        ]

        let firstWorker = cache.prewarm(items: staleItems)
        let coalescedWorker = cache.prewarm(items: latestItems)
        XCTAssertNotNil(firstWorker)
        XCTAssertNotNil(coalescedWorker)

        await coalescedWorker?.value

        XCTAssertNil(cache.cachedTitle(for: staleItems[0]))
        XCTAssertNil(cache.cachedMetadata(for: staleItems[1]))
        XCTAssertEqual(cache.cachedTitle(for: latestItems[0]), "latest-one")
        XCTAssertNotNil(cache.cachedMetadata(for: latestItems[1]))
        XCTAssertEqual(cache.prewarmInFlightCountForTesting, 0)
        XCTAssertFalse(cache.hasActivePrewarmWorkerForTesting)
        XCTAssertEqual(cache.cacheEntryCountsForTesting.title, 2)
        XCTAssertEqual(cache.cacheEntryCountsForTesting.metadata, 2)
    }

    @MainActor
    func testAllCachedLatestPrewarmCancelsStaleWorkWithoutAdmission() async {
        let cache = ClipboardItemDisplayText.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let latestItems = [
            makeTextItem(plainText: "cached-latest-one"),
            makeTextItem(plainText: "cached-latest-two")
        ]
        for item in latestItems {
            _ = cache.displayTexts(for: item)
        }
        let staleItems = [
            makeTextItem(plainText: "stale-old-search-one"),
            makeTextItem(plainText: "stale-old-search-two")
        ]

        let worker = cache.prewarm(items: staleItems)
        XCTAssertNotNil(worker)
        XCTAssertNil(cache.prewarm(items: latestItems))
        await worker?.value

        XCTAssertNil(cache.cachedTitle(for: staleItems[0]))
        XCTAssertNil(cache.cachedMetadata(for: staleItems[1]))
        XCTAssertEqual(cache.cachedTitle(for: latestItems[0]), "cached-latest-one")
        XCTAssertNotNil(cache.cachedMetadata(for: latestItems[1]))
        XCTAssertEqual(cache.prewarmInFlightCountForTesting, 0)
        XCTAssertFalse(cache.hasActivePrewarmWorkerForTesting)
    }

    @MainActor
    func testPresentationPrewarmCachesFilePreviewAndMenuSignalWithoutExactCapability() async {
        let markdownItem = makeTextItem(plainText: "# Title\n\nBody")
        let plainItem = makeTextItem(plainText: "plain sentence")
        let fileItem = makeFileItem(plainText: "/tmp/scopy-note.md", note: nil, fileSizeBytes: nil)

        HistoryItemPresentationCache.shared.clearCaches()

        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: markdownItem))
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: markdownItem))
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: plainItem))
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedFilePreview(for: fileItem))

        let task = HistoryItemPresentationCache.shared.prewarm(items: [markdownItem, plainItem, fileItem])
        await task?.value

        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: markdownItem))
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: plainItem))
        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: markdownItem), true)
        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: plainItem), false)

        let cachedFilePreview = HistoryItemPresentationCache.shared.cachedFilePreview(for: fileItem)
        XCTAssertEqual(cachedFilePreview?.path, "/tmp/scopy-note.md")
        XCTAssertEqual(cachedFilePreview?.isMarkdown, true)

        XCTAssertTrue(HistoryItemPresentationCache.shared.markdownExportCapability(for: markdownItem))
        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: markdownItem), true)
        XCTAssertTrue(HistoryItemPresentationCache.shared.canExportPNG(for: markdownItem, filePreview: nil))
        XCTAssertTrue(HistoryItemPresentationCache.shared.canExportPNG(for: fileItem, filePreview: cachedFilePreview))
    }

    private func makeTextItem(
        id: UUID = UUID(),
        contentHash: String = UUID().uuidString,
        plainText: String
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: .text,
            contentHash: contentHash,
            plainText: plainText,
            appBundleID: nil,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: plainText.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    private func makeFileItem(plainText: String, note: String?, fileSizeBytes: Int?) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .file,
            contentHash: UUID().uuidString,
            plainText: plainText,
            note: note,
            appBundleID: nil,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: plainText.utf8.count,
            fileSizeBytes: fileSizeBytes,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    // Reference implementation (pre-optimization) to guard behavior stability.
    private func legacyTextMetadata(_ text: String) -> String {
        let charCount = TextMetrics.displayWordUnitCount(for: text)
        let lineCount = text.components(separatedBy: .newlines).count
        let cleanText = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let lastChars = cleanText.count <= 15 ? cleanText : "...\(String(cleanText.suffix(15)))"
        return "\(charCount)字 · \(lineCount)行 · \(lastChars)"
    }

    private func legacyFileTitle(_ plainText: String) -> String {
        let paths = plainText.components(separatedBy: "\n").filter { !$0.isEmpty }
        let fileCount = paths.count
        let firstName = URL(fileURLWithPath: paths.first ?? "").lastPathComponent
        if fileCount <= 1 {
            return firstName.isEmpty ? plainText : firstName
        }
        return "\(firstName) + \(fileCount - 1) more"
    }

    private func legacyFileMetadata(_ plainText: String, note: String?, fileSizeBytes: Int?) -> String {
        let paths = plainText.components(separatedBy: "\n").filter { !$0.isEmpty }
        let fileCount = paths.count
        var parts: [String] = []

        if fileCount > 1 {
            parts.append("\(fileCount)个文件")
        }

        if let fileSizeBytes {
            parts.append(legacyFormatBytes(fileSizeBytes))
        } else {
            parts.append("未知大小")
        }

        if let note, !note.isEmpty {
            parts.append(note)
        }

        return parts.joined(separator: " · ")
    }

    private func legacyFormatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }
}
