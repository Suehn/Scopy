import Foundation
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryItemRowDescriptorTests: XCTestCase {
    func testInjectedDependenciesDriveDisplayAndPreviewFields() throws {
        let item = makeItem(
            type: .file,
            plainText: "/tmp/source.md",
            appBundleID: "com.scopy.source",
            thumbnailPath: "/tmp/source-thumb.png"
        )
        let preview = makePreviewSummary(
            path: "/tmp/source.md",
            kind: .other,
            isMarkdown: true,
            shouldGenerateThumbnail: true
        )
        let descriptor = HistoryItemRowDescriptor(
            item: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 72),
            dependencies: HistoryItemRowDescriptor.Dependencies(
                displayTexts: { received in
                    XCTAssertEqual(received.id, item.id)
                    return (title: "Injected title", metadata: "Injected metadata")
                },
                filePreview: { received in
                    XCTAssertEqual(received.id, item.id)
                    return preview
                }
            )
        )

        XCTAssertEqual(descriptor.titleText, "Injected title")
        XCTAssertEqual(descriptor.metadataText, "Injected metadata")
        XCTAssertEqual(descriptor.thumbnailHeight, 72)
        XCTAssertTrue(descriptor.showThumbnails)
        XCTAssertEqual(descriptor.filePreviewInfo?.url.path, "/tmp/source.md")
        XCTAssertEqual(descriptor.filePreviewInfo?.kind, .other)
        XCTAssertEqual(descriptor.filePreviewPath, "/tmp/source.md")
        XCTAssertEqual(descriptor.filePreviewKind, .other)
        XCTAssertTrue(descriptor.filePreviewIsMarkdown)
        XCTAssertTrue(descriptor.canShowFileThumbnail)
        XCTAssertTrue(descriptor.needsThumbnailHeight)
        XCTAssertEqual(descriptor.appIconBundleID, "com.scopy.source")
    }

    func testTextItemDoesNotUseFileThumbnailHeightAndMirrorsAppIconBundleID() {
        let item = makeItem(type: .text, plainText: "plain text", appBundleID: "com.scopy.text")

        let descriptor = HistoryItemRowDescriptor(
            item: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 64),
            dependencies: dependencies(
                title: "Text title",
                metadata: "Text metadata",
                filePreview: nil
            )
        )

        XCTAssertEqual(descriptor.titleText, "Text title")
        XCTAssertEqual(descriptor.metadataText, "Text metadata")
        XCTAssertEqual(descriptor.appIconBundleID, "com.scopy.text")
        XCTAssertEqual(descriptor.thumbnailHeight, 64)
        XCTAssertTrue(descriptor.showThumbnails)
        XCTAssertNil(descriptor.filePreviewInfo)
        XCTAssertNil(descriptor.filePreviewPath)
        XCTAssertNil(descriptor.filePreviewKind)
        XCTAssertFalse(descriptor.filePreviewIsMarkdown)
        XCTAssertFalse(descriptor.canShowFileThumbnail)
        XCTAssertFalse(descriptor.needsThumbnailHeight)
    }

    func testImageItemNeedsThumbnailHeightOnlyWhenThumbnailsAreEnabled() {
        let imageItem = makeItem(
            type: .image,
            plainText: "Image",
            thumbnailPath: "/tmp/image-thumb.png",
            storageRef: "/tmp/image.png"
        )

        let enabled = HistoryItemRowDescriptor(
            item: imageItem,
            settings: settings(showThumbnails: true, thumbnailHeight: 48),
            dependencies: dependencies(title: "Image", metadata: "10 KB")
        )
        let disabled = HistoryItemRowDescriptor(
            item: imageItem,
            settings: settings(showThumbnails: false, thumbnailHeight: 48),
            dependencies: dependencies(title: "Image", metadata: "10 KB")
        )

        XCTAssertTrue(enabled.showThumbnails)
        XCTAssertTrue(enabled.needsThumbnailHeight)
        XCTAssertFalse(enabled.canShowFileThumbnail)

        XCTAssertFalse(disabled.showThumbnails)
        XCTAssertFalse(disabled.needsThumbnailHeight)
        XCTAssertFalse(disabled.canShowFileThumbnail)
    }

    func testFileThumbnailFlagsRespectSettingsAndPreviewCapability() {
        let fileItem = makeItem(type: .file, plainText: "/tmp/image.png")
        let thumbnailPreview = makePreviewSummary(
            path: "/tmp/image.png",
            kind: .image,
            isMarkdown: false,
            shouldGenerateThumbnail: true
        )
        let nonThumbnailPreview = makePreviewSummary(
            path: "/tmp/readme.txt",
            kind: .other,
            isMarkdown: false,
            shouldGenerateThumbnail: false
        )

        let enabled = HistoryItemRowDescriptor(
            item: fileItem,
            settings: settings(showThumbnails: true, thumbnailHeight: 40),
            dependencies: dependencies(filePreview: thumbnailPreview)
        )
        let disabledBySettings = HistoryItemRowDescriptor(
            item: fileItem,
            settings: settings(showThumbnails: false, thumbnailHeight: 40),
            dependencies: dependencies(filePreview: thumbnailPreview)
        )
        let disabledByPreview = HistoryItemRowDescriptor(
            item: fileItem,
            settings: settings(showThumbnails: true, thumbnailHeight: 40),
            dependencies: dependencies(filePreview: nonThumbnailPreview)
        )

        XCTAssertTrue(enabled.canShowFileThumbnail)
        XCTAssertTrue(enabled.needsThumbnailHeight)
        XCTAssertEqual(enabled.filePreviewKind, .image)

        XCTAssertFalse(disabledBySettings.canShowFileThumbnail)
        XCTAssertFalse(disabledBySettings.needsThumbnailHeight)

        XCTAssertFalse(disabledByPreview.canShowFileThumbnail)
        XCTAssertFalse(disabledByPreview.needsThumbnailHeight)
        XCTAssertEqual(disabledByPreview.filePreviewKind, .other)
    }

    func testMarkdownFilePreviewAndTextPreviewFieldsStaySeparate() {
        let markdownFile = makeItem(type: .file, plainText: "/tmp/note.md")
        let markdownPreview = makePreviewSummary(
            path: "/tmp/note.md",
            kind: .other,
            isMarkdown: true,
            shouldGenerateThumbnail: false
        )
        let fileDescriptor = HistoryItemRowDescriptor(
            item: markdownFile,
            settings: settings(),
            dependencies: dependencies(filePreview: markdownPreview)
        )

        let markdownText = makeItem(type: .text, plainText: "# Title")
        let textDescriptor = HistoryItemRowDescriptor(
            item: markdownText,
            settings: settings(),
            dependencies: dependencies(filePreview: nil)
        )

        XCTAssertTrue(fileDescriptor.filePreviewIsMarkdown)
        XCTAssertEqual(fileDescriptor.filePreviewPath, "/tmp/note.md")
        XCTAssertFalse(fileDescriptor.canShowFileThumbnail)

        XCTAssertFalse(textDescriptor.filePreviewIsMarkdown)
        XCTAssertNil(textDescriptor.filePreviewPath)
    }

    func testPresentationCacheReusesRowDescriptorForSameItemAndSettings() {
        let item = makeItem(type: .text, plainText: "cached descriptor")
        var displayCallCount = 0
        var filePreviewCallCount = 0
        HistoryItemPresentationCache.shared.clearCaches()

        let cachedSettings = settings()
        let dependencies = HistoryItemRowDescriptor.Dependencies(
            displayTexts: { _ in
                displayCallCount += 1
                return (title: "Cached title", metadata: "Cached metadata")
            },
            filePreview: { _ in
                filePreviewCallCount += 1
                return nil
            }
        )

        let first = HistoryItemPresentationCache.shared.rowDescriptor(
            for: item,
            settings: cachedSettings,
            dependencies: dependencies
        )
        let second = HistoryItemPresentationCache.shared.rowDescriptor(
            for: item,
            settings: cachedSettings,
            dependencies: HistoryItemRowDescriptor.Dependencies(
                displayTexts: { _ in
                    XCTFail("Expected cached row descriptor to skip display text recomputation")
                    return (title: "Unexpected", metadata: "Unexpected")
                },
                filePreview: { _ in
                    XCTFail("Expected cached row descriptor to skip file preview recomputation")
                    return nil
                }
            )
        )

        XCTAssertEqual(first.titleText, "Cached title")
        XCTAssertEqual(second.titleText, "Cached title")
        XCTAssertEqual(second.metadataText, "Cached metadata")
        XCTAssertEqual(displayCallCount, 1)
        XCTAssertEqual(filePreviewCallCount, 1)
    }

    func testPresentationCacheSeparatesRowDescriptorsByThumbnailSettings() {
        let item = makeItem(type: .image, plainText: "image")
        var displayCallCount = 0
        HistoryItemPresentationCache.shared.clearCaches()

        let dependencies = HistoryItemRowDescriptor.Dependencies(
            displayTexts: { _ in
                displayCallCount += 1
                return (title: "Image", metadata: "10 KB")
            },
            filePreview: { _ in nil }
        )

        let compact = HistoryItemPresentationCache.shared.rowDescriptor(
            for: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 40),
            dependencies: dependencies
        )
        let large = HistoryItemPresentationCache.shared.rowDescriptor(
            for: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 80),
            dependencies: dependencies
        )

        XCTAssertEqual(compact.thumbnailHeight, 40)
        XCTAssertEqual(large.thumbnailHeight, 80)
        XCTAssertEqual(displayCallCount, 2)
    }

    func testPresentationCacheSeparatesSameIDMissingHashEqualLengthContent() {
        let itemID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let first = makeItem(id: itemID, contentHash: "", type: .text, plainText: "AB")
        let replacement = makeItem(id: itemID, contentHash: "", type: .text, plainText: "CD")
        var displayCallCount = 0
        HistoryItemPresentationCache.shared.clearCaches()

        let firstDescriptor = HistoryItemPresentationCache.shared.rowDescriptor(
            for: first,
            settings: settings(),
            dependencies: HistoryItemRowDescriptor.Dependencies(
                displayTexts: { _ in
                    displayCallCount += 1
                    return (title: "AB", metadata: "first")
                },
                filePreview: { _ in nil }
            )
        )
        let replacementDescriptor = HistoryItemPresentationCache.shared.rowDescriptor(
            for: replacement,
            settings: settings(),
            dependencies: HistoryItemRowDescriptor.Dependencies(
                displayTexts: { _ in
                    displayCallCount += 1
                    return (title: "CD", metadata: "replacement")
                },
                filePreview: { _ in nil }
            )
        )

        XCTAssertEqual(firstDescriptor.titleText, "AB")
        XCTAssertEqual(replacementDescriptor.titleText, "CD")
        XCTAssertEqual(displayCallCount, 2)
    }

    func testMarkdownCapabilityCacheInvalidatesForSameIDContentRevision() {
        let itemID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let first = makeItem(id: itemID, contentHash: "", type: .text, plainText: "#A")
        let replacement = makeItem(id: itemID, contentHash: "", type: .text, plainText: "AB")
        HistoryItemPresentationCache.shared.clearCaches()

        HistoryItemPresentationCache.shared.storeMarkdownExportCapability(true, for: first)

        XCTAssertEqual(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: first), true)
        XCTAssertNil(HistoryItemPresentationCache.shared.cachedMarkdownExportCapability(for: replacement))
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

        cache.storeMarkdownExportCapability(false, for: firstText)
        cache.storeMarkdownExportCapability(true, for: secondText)
        cache.storeMarkdownExportCapability(false, for: replacementText)
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

        for _ in 0..<1_000 {
            if cache.activePrewarmInFlightCountForTesting > 0 { break }
            await Task.yield()
        }
        XCTAssertGreaterThan(cache.activePrewarmInFlightCountForTesting, 0)

        XCTAssertNil(cache.prewarm(items: [latestText, latestFile]))
        await worker?.value

        XCTAssertNil(cache.cachedMarkdownMenuSignal(for: staleItems[0]))
        XCTAssertEqual(cache.cachedMarkdownMenuSignal(for: latestText), false)
        XCTAssertEqual(cache.cachedFilePreview(for: latestFile)?.path, "/tmp/cached-active-latest.md")
        XCTAssertEqual(cache.prewarmInFlightCountForTesting, 0)
        XCTAssertFalse(cache.hasActivePrewarmWorkerForTesting)
    }

    func testMarkdownMenuSignalPrewarmIsBoundedAndClearedWithPresentationCaches() async {
        HistoryItemPresentationCache.shared.clearCaches()

        let items = (0...4_096).map { index in
            makeItem(
                contentHash: "menu-signal-\(index)",
                type: .text,
                plainText: index.isMultiple(of: 2) ? "# title" : "plain"
            )
        }
        let task = HistoryItemPresentationCache.shared.prewarm(items: items)
        await task?.value

        XCTAssertEqual(HistoryItemPresentationCache.shared.markdownMenuSignalEntryCountForTesting, 4_096)
        HistoryItemPresentationCache.shared.clearCaches()
        XCTAssertEqual(HistoryItemPresentationCache.shared.markdownMenuSignalEntryCountForTesting, 0)
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

    private func dependencies(
        title: String = "Title",
        metadata: String = "Metadata",
        filePreview: FilePreviewSummary? = nil
    ) -> HistoryItemRowDescriptor.Dependencies {
        HistoryItemRowDescriptor.Dependencies(
            displayTexts: { _ in (title: title, metadata: metadata) },
            filePreview: { _ in filePreview }
        )
    }

    private func settings(showThumbnails: Bool = true, thumbnailHeight: Int = 40) -> SettingsDTO {
        var settings = SettingsDTO.default
        settings.showImageThumbnails = showThumbnails
        settings.thumbnailHeight = thumbnailHeight
        return settings
    }

    private func makePreviewSummary(
        path: String,
        kind: FilePreviewKind,
        isMarkdown: Bool,
        shouldGenerateThumbnail: Bool
    ) -> FilePreviewSummary {
        guard let info = FilePreviewSupport.previewInfo(from: path, requireExists: false) else {
            preconditionFailure("Expected test path to produce FilePreviewInfo: \(path)")
        }
        return FilePreviewSummary(
            info: info,
            path: path,
            kind: kind,
            isMarkdown: isMarkdown,
            shouldGenerateThumbnail: shouldGenerateThumbnail
        )
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
