import Foundation
import ScopyKit
import XCTest

@testable import Scopy

@MainActor
final class ClipboardItemContentRevisionTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            ClipboardItemDisplayText.shared.clearCaches()
            HistoryItemPresentationCache.shared.clearCaches()
        }
        super.tearDown()
    }

    func testSameIDMissingHashSeparatesEqualLengthContent() {
        let itemID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let first = makeItem(id: itemID, contentHash: "", plainText: "AB")
        let replacement = makeItem(id: itemID, contentHash: "", plainText: "CD")

        let firstRevision = ClipboardItemContentRevision(item: first)
        let replacementRevision = ClipboardItemContentRevision(item: replacement)

        XCTAssertNotEqual(firstRevision, replacementRevision)
        XCTAssertNotEqual(firstRevision.cacheKey, replacementRevision.cacheKey)
        XCTAssertNotEqual(
            ClipboardItemContentRevision.deterministicTextCacheKey(first.plainText),
            ClipboardItemContentRevision.deterministicTextCacheKey(replacement.plainText)
        )
    }

    func testSameIDChangedSuppliedHashCreatesNewRevision() {
        let itemID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let first = makeItem(id: itemID, contentHash: "content-a", plainText: "same display text")
        let replacement = makeItem(id: itemID, contentHash: "content-b", plainText: "same display text")

        XCTAssertNotEqual(
            ClipboardItemContentRevision(item: first),
            ClipboardItemContentRevision(item: replacement)
        )
    }

    func testConstructionIsStableAcrossNonContentChanges() {
        let itemID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let first = makeItem(
            id: itemID,
            contentHash: "",
            plainText: "stable fallback",
            note: nil,
            lastUsedAt: Date(timeIntervalSince1970: 1),
            isPinned: false
        )
        let sameContent = makeItem(
            id: itemID,
            contentHash: "",
            plainText: "stable fallback",
            note: "presentation note",
            lastUsedAt: Date(timeIntervalSince1970: 2),
            isPinned: true
        )

        let firstRevision = ClipboardItemContentRevision(item: first)
        let secondRevision = ClipboardItemContentRevision(item: sameContent)

        XCTAssertEqual(firstRevision, secondRevision)
        XCTAssertEqual(firstRevision.cacheKey, secondRevision.cacheKey)
        XCTAssertEqual(
            firstRevision.cacheKey,
            "content-v1|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|" +
                "8337686fa0a8cfb2737c1a9a0356009f9790b255be174d673cc80702b3a002d5"
        )
        XCTAssertEqual(
            ClipboardItemContentRevision.deterministicTextCacheKey(first.plainText),
            "text-v1|905a73d5a62aee7a369e34d29ad978ce4481dcb2012c924fa4f356d6722c8b17"
        )
        assertSendable(firstRevision)
    }

    func testContentLocationParticipatesInRevision() {
        let itemID = UUID(uuidString: "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb")!
        let first = makeItem(
            id: itemID,
            contentHash: "image-hash",
            plainText: "Image",
            storageRef: "/tmp/first.png"
        )
        let replacement = makeItem(
            id: itemID,
            contentHash: "image-hash",
            plainText: "Image",
            storageRef: "/tmp/second.png"
        )

        XCTAssertNotEqual(
            ClipboardItemContentRevision(item: first),
            ClipboardItemContentRevision(item: replacement)
        )
    }

    func testNonTextPresentationSourceParticipatesWhenSuppliedHashIsUnchanged() {
        let itemID = UUID(uuidString: "ffffffff-1111-2222-3333-444444444444")!
        let first = makeItem(
            id: itemID,
            contentHash: "shared-binary-hash",
            plainText: "[Image: 100x100]",
            storageRef: "/tmp/image.png"
        )
        let replacement = makeItem(
            id: itemID,
            contentHash: "shared-binary-hash",
            plainText: "[Image: 200x200]",
            storageRef: "/tmp/image.png"
        )

        XCTAssertNotEqual(
            ClipboardItemContentRevision(item: first),
            ClipboardItemContentRevision(item: replacement)
        )
    }

    func testThumbnailGenerationDoesNotChangeContentRevisionButInvalidatesRowPresentation() {
        let itemID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let original = makeItem(
            id: itemID,
            contentHash: "image-hash",
            plainText: "Image",
            thumbnailPath: nil,
            storageRef: "/tmp/original.png"
        )
        let thumbnailGenerated = makeItem(
            id: itemID,
            contentHash: "image-hash",
            plainText: "Image",
            thumbnailPath: "/tmp/generated-thumbnail.png",
            storageRef: "/tmp/original.png"
        )

        let originalRevision = ClipboardItemContentRevision(item: original)
        let generatedRevision = ClipboardItemContentRevision(item: thumbnailGenerated)
        XCTAssertEqual(originalRevision, generatedRevision)
        XCTAssertEqual(originalRevision.cacheKey, generatedRevision.cacheKey)
        XCTAssertFalse(makeView(item: original) == makeView(item: thumbnailGenerated))

        HistoryItemPresentationCache.shared.clearCaches()
        var displayTextCallCount = 0
        let dependencies = HistoryItemRowDescriptor.Dependencies(
            displayTexts: { _ in
                displayTextCallCount += 1
                return ("Image", "metadata")
            },
            filePreview: { _ in nil }
        )
        _ = HistoryItemPresentationCache.shared.rowDescriptor(
            for: original,
            settings: .default,
            dependencies: dependencies
        )
        _ = HistoryItemPresentationCache.shared.rowDescriptor(
            for: thumbnailGenerated,
            settings: .default,
            dependencies: dependencies
        )
        _ = HistoryItemPresentationCache.shared.rowDescriptor(
            for: thumbnailGenerated,
            settings: .default,
            dependencies: dependencies
        )
        XCTAssertEqual(displayTextCallCount, 2)
    }

    func testHistoryItemViewEqualityRejectsSameIDMissingHashReplacement() {
        let itemID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let first = makeItem(id: itemID, contentHash: "", plainText: "AB")
        let replacement = makeItem(id: itemID, contentHash: "", plainText: "CD")

        XCTAssertFalse(makeView(item: first) == makeView(item: replacement))
    }

    func testHistoryItemViewEqualityRejectsEveryMarkdownExportSettingChange() {
        let item = makeItem(id: UUID(), contentHash: "hash", plainText: "# Markdown")
        let baseline = SettingsDTO.default
        var variants: [SettingsDTO] = []

        var binaryPath = baseline
        binaryPath.pngquantBinaryPath = "/tmp/pngquant-other"
        variants.append(binaryPath)

        var enabled = baseline
        enabled.pngquantMarkdownExportEnabled.toggle()
        variants.append(enabled)

        var qualityMin = baseline
        qualityMin.pngquantMarkdownExportQualityMin += 1
        variants.append(qualityMin)

        var qualityMax = baseline
        qualityMax.pngquantMarkdownExportQualityMax += 1
        variants.append(qualityMax)

        var speed = baseline
        speed.pngquantMarkdownExportSpeed += 1
        variants.append(speed)

        var colors = baseline
        colors.pngquantMarkdownExportColors -= 1
        variants.append(colors)

        var layoutScale = baseline
        layoutScale.markdownChatGPTLayoutScalePercent += 1
        variants.append(layoutScale)

        for variant in variants {
            XCTAssertFalse(
                makeView(item: item, settings: baseline) ==
                    makeView(item: item, settings: variant)
            )
        }
    }

    func testOptimizeButtonPolicyHonorsScrollSuppressionForHoverAndSelection() {
        XCTAssertTrue(
            HistoryItemView.shouldShowOptimizeButton(
                itemType: .image,
                isHovering: true,
                isKeyboardSelected: false,
                isInteractionSuppressed: false
            )
        )
        XCTAssertTrue(
            HistoryItemView.shouldShowOptimizeButton(
                itemType: .image,
                isHovering: false,
                isKeyboardSelected: true,
                isInteractionSuppressed: false
            )
        )
        XCTAssertFalse(
            HistoryItemView.shouldShowOptimizeButton(
                itemType: .image,
                isHovering: true,
                isKeyboardSelected: true,
                isInteractionSuppressed: true
            )
        )
        XCTAssertFalse(
            HistoryItemView.shouldShowOptimizeButton(
                itemType: .text,
                isHovering: true,
                isKeyboardSelected: true,
                isInteractionSuppressed: false
            )
        )
    }

    private func makeItem(
        id: UUID,
        contentHash: String,
        plainText: String,
        note: String? = nil,
        lastUsedAt: Date = Date(timeIntervalSince1970: 1),
        isPinned: Bool = false,
        thumbnailPath: String? = nil,
        storageRef: String? = nil
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: storageRef == nil ? .text : .image,
            contentHash: contentHash,
            plainText: plainText,
            note: note,
            appBundleID: "com.scopy.tests",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: lastUsedAt,
            isPinned: isPinned,
            sizeBytes: plainText.utf8.count,
            fileSizeBytes: nil,
            thumbnailPath: thumbnailPath,
            storageRef: storageRef
        )
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }

    private func makeView(
        item: ClipboardItemDTO,
        settings: SettingsDTO = .default
    ) -> HistoryItemView {
        HistoryItemView(
            item: item,
            isKeyboardSelected: false,
            settings: settings,
            onSelect: {},
            onSelectOptimizedForCodex: {},
            onSendViaAirDrop: {},
            onOpenContainingFolder: {},
            onHoverSelect: { _ in },
            onTogglePin: {},
            onDelete: {},
            onUpdateNote: { _ in true },
            onOptimizeImage: { fatalError("unused test callback") },
            getImageData: { nil },
            markdownWebViewController: MarkdownPreviewWebViewController(),
            interactionCoordinator: HistoryListInteractionCoordinator(),
            interactionSessionStore: HistoryItemInteractionSessionStore(),
            isContentRevisionCurrent: { itemID, revision in
                itemID == item.id && ClipboardItemContentRevision(item: item) == revision
            },
            isImagePreviewPresented: false,
            isTextPreviewPresented: false,
            isFilePreviewPresented: false,
            requestPopover: { _ in },
            dismissOtherPopovers: {}
        )
    }
}
