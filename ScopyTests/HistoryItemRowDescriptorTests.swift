import Foundation
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryItemRowDescriptorTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            ClipboardItemDisplayText.shared.clearCaches()
            HistoryItemPresentationCache.shared.clearCaches()
        }
        super.tearDown()
    }

    func testTextDescriptorUsesLiveDisplayWithoutFilePreview() {
        let item = makeItem(type: .text, plainText: "plain text", appBundleID: "com.scopy.text")
        let descriptor = HistoryItemRowDescriptor(
            item: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 64)
        )

        XCTAssertEqual(descriptor.titleText, "plain text")
        XCTAssertTrue(descriptor.metadataText.hasSuffix(" · plain text"))
        XCTAssertNotNil(descriptor.searchMetadataPrefix)
        XCTAssertEqual(descriptor.appIconBundleID, "com.scopy.text")
        XCTAssertFalse(descriptor.needsThumbnailHeight)
        XCTAssertNil(descriptor.filePreviewInfo)
        XCTAssertNil(descriptor.filePreviewPath)
    }

    func testFileThumbnailFlagsRespectSettingsAndPreviewCapability() {
        let imageFile = makeItem(type: .file, plainText: "/tmp/image.png")
        let textFile = makeItem(type: .file, plainText: "/tmp/readme.txt")
        let enabled = HistoryItemRowDescriptor(
            item: imageFile,
            settings: settings(showThumbnails: true, thumbnailHeight: 40)
        )
        let disabledBySettings = HistoryItemRowDescriptor(
            item: imageFile,
            settings: settings(showThumbnails: false, thumbnailHeight: 40)
        )
        let disabledByPreview = HistoryItemRowDescriptor(
            item: textFile,
            settings: settings(showThumbnails: true, thumbnailHeight: 40)
        )

        XCTAssertEqual(enabled.titleText, "image.png")
        XCTAssertEqual(enabled.filePreviewInfo?.url.path, "/tmp/image.png")
        XCTAssertEqual(enabled.filePreviewKind, .image)
        XCTAssertTrue(enabled.canShowFileThumbnail)
        XCTAssertTrue(enabled.needsThumbnailHeight)
        XCTAssertFalse(disabledBySettings.canShowFileThumbnail)
        XCTAssertFalse(disabledBySettings.needsThumbnailHeight)
        XCTAssertEqual(disabledByPreview.titleText, "readme.txt")
        XCTAssertFalse(disabledByPreview.canShowFileThumbnail)
        XCTAssertFalse(disabledByPreview.needsThumbnailHeight)
        XCTAssertEqual(disabledByPreview.filePreviewKind, .other)
    }

    func testMarkdownFilePreviewAndTextPreviewFieldsStaySeparate() {
        let fileDescriptor = HistoryItemRowDescriptor(
            item: makeItem(type: .file, plainText: "/tmp/note.md"),
            settings: settings()
        )
        let textDescriptor = HistoryItemRowDescriptor(
            item: makeItem(type: .text, plainText: "# Title"),
            settings: settings()
        )

        XCTAssertEqual(fileDescriptor.titleText, "note.md")
        XCTAssertTrue(fileDescriptor.filePreviewIsMarkdown)
        XCTAssertEqual(fileDescriptor.filePreviewPath, "/tmp/note.md")
        XCTAssertFalse(fileDescriptor.canShowFileThumbnail)
        XCTAssertEqual(textDescriptor.titleText, "# Title")
        XCTAssertFalse(textDescriptor.filePreviewIsMarkdown)
        XCTAssertNil(textDescriptor.filePreviewPath)
    }

    func testPresentationCacheSeparatesRowDescriptorsByThumbnailSettings() {
        let item = makeItem(type: .image, plainText: "[Image: 100x100]")
        let cache = HistoryItemPresentationCache.shared
        let compact = cache.rowDescriptor(
            for: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 40)
        )
        let large = cache.rowDescriptor(
            for: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 80)
        )
        let hidden = cache.rowDescriptor(
            for: item,
            settings: settings(showThumbnails: false, thumbnailHeight: 80)
        )

        XCTAssertEqual(compact.thumbnailHeight, 40)
        XCTAssertEqual(large.thumbnailHeight, 80)
        XCTAssertTrue(compact.needsThumbnailHeight)
        XCTAssertTrue(large.needsThumbnailHeight)
        XCTAssertFalse(hidden.showThumbnails)
        XCTAssertFalse(hidden.needsThumbnailHeight)
        XCTAssertEqual(compact.titleText, String(localized: "Image"))
        XCTAssertTrue(compact.metadataText.contains("100×100"))
        XCTAssertEqual(compact.metadataText, hidden.metadataText)
    }

    func testPresentationCacheSeparatesSameIDMissingHashEqualLengthContent() {
        let itemID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let first = makeItem(id: itemID, contentHash: "", type: .text, plainText: "AB")
        let replacement = makeItem(id: itemID, contentHash: "", type: .text, plainText: "CD")
        let cache = HistoryItemPresentationCache.shared
        let firstDescriptor = cache.rowDescriptor(for: first, settings: settings())
        let replacementDescriptor = cache.rowDescriptor(for: replacement, settings: settings())

        XCTAssertEqual(firstDescriptor.titleText, "AB")
        XCTAssertEqual(replacementDescriptor.titleText, "CD")
        XCTAssertTrue(firstDescriptor.metadataText.hasSuffix(" · AB"))
        XCTAssertTrue(replacementDescriptor.metadataText.hasSuffix(" · CD"))
        XCTAssertEqual(cache.cachedRowDescriptor(for: first, settings: settings())?.titleText, "AB")
        XCTAssertEqual(cache.cachedRowDescriptor(for: replacement, settings: settings())?.titleText, "CD")
    }

    func testMarkdownCapabilityCacheInvalidatesForSameIDContentRevision() {
        let itemID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let first = makeItem(id: itemID, contentHash: "", type: .text, plainText: "# A\n\nBody")
        let replacement = makeItem(id: itemID, contentHash: "", type: .text, plainText: "AB")
        HistoryItemPresentationCache.shared.clearCaches()

        XCTAssertTrue(HistoryItemPresentationCache.shared.markdownExportCapability(for: first))

        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: first), true)
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: replacement))
        XCTAssertFalse(HistoryItemPresentationCache.shared.markdownExportCapability(for: replacement))
    }

    func testMarkdownMenuSignalCacheInvalidatesForSameIDContentRevision() {
        let itemID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let first = makeItem(id: itemID, contentHash: "", type: .text, plainText: "#A")
        let replacement = makeItem(id: itemID, contentHash: "", type: .text, plainText: "AB")
        HistoryItemPresentationCache.shared.clearCaches()

        XCTAssertTrue(HistoryItemPresentationCache.shared.markdownMenuSignal(for: first))
        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: first), true)
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: replacement))
        XCTAssertFalse(HistoryItemPresentationCache.shared.markdownMenuSignal(for: replacement))
    }

    func testPresentationCachesEvictFIFOAndAdmitNewValuesAtExactCapacity() {
        let cache = HistoryItemPresentationCache.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let replacedID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let firstText = makeItem(
            id: replacedID,
            contentHash: "",
            type: .text,
            plainText: "plain first"
        )
        let secondText = makeItem(type: .text, plainText: "# second")
        let replacementText = makeItem(
            id: replacedID,
            contentHash: "",
            type: .text,
            plainText: "plain replacement"
        )
        let cachedSettings = settings()

        _ = cache.rowDescriptor(for: firstText, settings: cachedSettings)
        _ = cache.rowDescriptor(for: secondText, settings: cachedSettings)
        _ = cache.rowDescriptor(for: replacementText, settings: cachedSettings)

        XCTAssertNil(cache.cachedRowDescriptor(for: firstText, settings: cachedSettings))
        XCTAssertNotNil(cache.cachedRowDescriptor(for: secondText, settings: cachedSettings))
        XCTAssertNotNil(cache.cachedRowDescriptor(for: replacementText, settings: cachedSettings))

        let firstFile = makeItem(type: .file, plainText: "/tmp/first.md")
        let secondFile = makeItem(type: .file, plainText: "/tmp/second.md")
        let thirdFile = makeItem(type: .file, plainText: "/tmp/third.md")
        _ = cache.filePreview(for: firstFile)
        _ = cache.filePreview(for: secondFile)
        _ = cache.filePreview(for: thirdFile)

        XCTAssertNil(cache.cachedFilePreview(for: firstFile))
        XCTAssertEqual(cache.cachedFilePreview(for: thirdFile)?.path, "/tmp/third.md")

        XCTAssertFalse(cache.markdownExportCapability(for: firstText))
        XCTAssertTrue(cache.markdownExportCapability(for: secondText))
        XCTAssertFalse(cache.markdownExportCapability(for: replacementText))
        XCTAssertNil(cache.cachedMarkdownExportCapability(for: firstText))
        XCTAssertEqual(cache.cachedMarkdownExportCapability(for: replacementText), false)

        XCTAssertFalse(cache.markdownMenuSignal(for: firstText))
        XCTAssertTrue(cache.markdownMenuSignal(for: secondText))
        XCTAssertFalse(cache.markdownMenuSignal(for: replacementText))
        XCTAssertNil(cache.cachedMarkdownMenuSignal(for: firstText))
        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: replacementText), false)

        let relativeFirst = makeItem(type: .text, plainText: "relative first")
        let relativeSecond = makeItem(type: .text, plainText: "relative second")
        let relativeThird = makeItem(type: .text, plainText: "relative third")
        _ = cache.relativeTimeText(for: relativeFirst, bucket: 100)
        _ = cache.relativeTimeText(for: relativeSecond, bucket: 100)
        _ = cache.relativeTimeText(for: relativeThird, bucket: 100)
        XCTAssertNil(cache.relativeTimeBucketForTesting(itemID: relativeFirst.id))
        XCTAssertEqual(cache.relativeTimeBucketForTesting(itemID: relativeThird.id), 100)

        let counts = cache.cacheEntryCountsForTesting
        XCTAssertEqual(counts.rowDescriptor, 2)
        XCTAssertEqual(counts.filePreview, 2)
        XCTAssertEqual(counts.markdownMenuSignal, 2)
        XCTAssertEqual(counts.markdownCapability, 2)
        XCTAssertEqual(counts.relativeTime, 2)
    }

    func testPresentationPrewarmCoalescesRapidSupersessionAndCleansBookkeeping() async {
        let cache = HistoryItemPresentationCache.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let staleItems = [
            makeItem(type: .text, plainText: "# stale one"),
            makeItem(type: .file, plainText: "/tmp/stale.md")
        ]
        let latestItems = [
            makeItem(type: .text, plainText: "latest plain text"),
            makeItem(type: .file, plainText: "/tmp/latest.md")
        ]

        let firstWorker = cache.prewarm(items: staleItems)
        let coalescedWorker = cache.prewarm(items: latestItems)
        XCTAssertNotNil(firstWorker)
        XCTAssertNotNil(coalescedWorker)

        await coalescedWorker?.value

        XCTAssertNil(cache.cachedMarkdownMenuSignal(for: staleItems[0]))
        XCTAssertNil(cache.cachedFilePreview(for: staleItems[1]))
        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: latestItems[0]), false)
        XCTAssertEqual(cache.cachedFilePreview(for: latestItems[1])?.path, "/tmp/latest.md")
        XCTAssertEqual(cache.prewarmInFlightCountForTesting, 0)
        XCTAssertFalse(cache.hasActivePrewarmWorkerForTesting)
    }

    func testAllCachedLatestPresentationPrewarmCancelsStaleWorkWithoutAdmission() async {
        let cache = HistoryItemPresentationCache.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let latestItems = [
            makeItem(type: .text, plainText: "cached latest plain"),
            makeItem(type: .file, plainText: "/tmp/cached-latest.md")
        ]
        _ = cache.markdownMenuSignal(for: latestItems[0])
        _ = cache.filePreview(for: latestItems[1])

        let staleItems = [
            makeItem(type: .text, plainText: "# stale old search"),
            makeItem(type: .file, plainText: "/tmp/stale-old-search.md")
        ]
        let worker = cache.prewarm(items: staleItems)
        XCTAssertNotNil(worker)
        XCTAssertNil(cache.prewarm(items: latestItems))
        await worker?.value

        XCTAssertNil(cache.cachedMarkdownMenuSignal(for: staleItems[0]))
        XCTAssertNil(cache.cachedFilePreview(for: staleItems[1]))
        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: latestItems[0]), false)
        XCTAssertEqual(cache.cachedFilePreview(for: latestItems[1])?.path, "/tmp/cached-latest.md")
        XCTAssertEqual(cache.prewarmInFlightCountForTesting, 0)
        XCTAssertFalse(cache.hasActivePrewarmWorkerForTesting)
    }

    func testAllCachedLatestPresentationPrewarmCancelsAlreadyActiveStaleWork() async {
        let cache = HistoryItemPresentationCache.shared
        cache.configureCacheCapacityForTesting(4_096)
        defer { cache.restoreDefaultCacheCapacityForTesting() }

        let latestText = makeItem(type: .text, plainText: "cached active latest plain")
        let latestFile = makeItem(type: .file, plainText: "/tmp/cached-active-latest.md")
        _ = cache.markdownMenuSignal(for: latestText)
        _ = cache.filePreview(for: latestFile)

        let scanText = String(repeating: "plain text without markdown marker ", count: 160)
        let staleItems = (0..<4_096).map { index in
            makeItem(
                contentHash: "active-stale-\(index)",
                type: .text,
                plainText: scanText
            )
        }
        let worker = cache.prewarm(items: staleItems)
        XCTAssertNotNil(worker)

        await assertEventually(pollInterval: 0.001, {
            cache.activePrewarmInFlightCountForTesting > 0
        }, message: "The stale prewarm should be admitted before it is superseded")

        XCTAssertNil(cache.prewarm(items: [latestText, latestFile]))
        await worker?.value

        XCTAssertNil(cache.cachedMarkdownMenuSignal(for: staleItems[0]))
        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: latestText), false)
        XCTAssertEqual(cache.cachedFilePreview(for: latestFile)?.path, "/tmp/cached-active-latest.md")
        XCTAssertEqual(cache.prewarmInFlightCountForTesting, 0)
        XCTAssertFalse(cache.hasActivePrewarmWorkerForTesting)
    }

    func testMarkdownMenuSignalPrewarmIsBoundedAndClearedWithPresentationCaches() async {
        let cache = HistoryItemPresentationCache.shared
        cache.configureCacheCapacityForTesting(2)
        defer { cache.restoreDefaultCacheCapacityForTesting() }
        let items = (0..<3).map { index in
            makeItem(
                contentHash: "menu-signal-\(index)",
                type: .text,
                plainText: index.isMultiple(of: 2) ? "# title" : "plain"
            )
        }
        await cache.prewarm(items: items)?.value

        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: items[0]), true)
        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: items[1]), false)
        XCTAssertNil(cache.cachedMarkdownMenuSignal(for: items[2]))
        XCTAssertEqual(cache.markdownMenuSignalEntryCountForTesting, 2)
        cache.clearCaches()
        XCTAssertEqual(cache.markdownMenuSignalEntryCountForTesting, 0)
    }

    func testMarkdownMenuSignalPrewarmDeduplicatesInFlightRevision() async {
        HistoryItemPresentationCache.shared.clearCaches()
        let item = makeItem(
            contentHash: "menu-signal-in-flight",
            type: .text,
            plainText: "# title"
        )

        let first = HistoryItemPresentationCache.shared.prewarm(items: [item])
        let duplicate = HistoryItemPresentationCache.shared.prewarm(items: [item])

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
        await first?.value
        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: item), true)
    }

    func testClearCachesRejectsInFlightMarkdownMenuSignalPrewarm() async {
        HistoryItemPresentationCache.shared.clearCaches()
        let item = makeItem(
            contentHash: "menu-signal-stale-generation",
            type: .text,
            plainText: "# title"
        )

        let stale = HistoryItemPresentationCache.shared.prewarm(items: [item])
        HistoryItemPresentationCache.shared.clearCaches()
        await stale?.value

        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownMenuSignal(for: item))
    }

    func testFilePreviewCacheSeparatesSameIDContentRevision() {
        let fileID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let firstFile = makeItem(
            id: fileID,
            contentHash: "",
            type: .file,
            plainText: "/tmp/a.md"
        )
        let replacementFile = makeItem(
            id: fileID,
            contentHash: "",
            type: .file,
            plainText: "/tmp/b.md"
        )
        HistoryItemPresentationCache.shared.clearCaches()

        XCTAssertEqual(
            HistoryItemPresentationCache.shared.filePreview(for: firstFile)?.path,
            "/tmp/a.md"
        )
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedFilePreview(for: replacementFile))
        XCTAssertEqual(
            HistoryItemPresentationCache.shared.filePreview(for: replacementFile)?.path,
            "/tmp/b.md"
        )
    }

    func testRowDescriptorDoesNotPopulateMarkdownExportCapability() {
        let item = makeItem(type: .text, plainText: "# Title\n\nBody")
        HistoryItemPresentationCache.shared.clearCaches()

        _ = HistoryItemPresentationCache.shared.rowDescriptor(for: item, settings: settings())

        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: item))
    }

    private func settings(showThumbnails: Bool = true, thumbnailHeight: Int = 40) -> SettingsDTO {
        var settings = SettingsDTO.default
        settings.showImageThumbnails = showThumbnails
        settings.thumbnailHeight = thumbnailHeight
        return settings
    }

    private func makeItem(
        id: UUID = UUID(),
        contentHash: String = UUID().uuidString,
        type: ClipboardItemType,
        plainText: String,
        appBundleID: String? = nil,
        thumbnailPath: String? = nil,
        storageRef: String? = nil
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            appBundleID: appBundleID,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: plainText.utf8.count,
            thumbnailPath: thumbnailPath,
            storageRef: storageRef
        )
    }
}
