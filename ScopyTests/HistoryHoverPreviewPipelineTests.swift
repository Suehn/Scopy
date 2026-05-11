import CoreGraphics
import Foundation
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryHoverPreviewPipelineTests: XCTestCase {
    override func tearDown() {
        HoverPreviewImageCache.shared.removeAll()
        HistoryItemPresentationCache.shared.clearCaches()
        super.tearDown()
    }

    func testImagePlanUsesContentHashWidthAndDelay() {
        let itemID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = HistoryHoverPreviewPipeline.ImageRequest(
            itemID: itemID,
            contentHash: "hash-a",
            storageRef: "/tmp/image.png",
            delay: 0.25,
            scale: 2,
            targetWidthPoints: 640,
            maxLongSidePixels: 12_000
        )

        let plan = HistoryHoverPreviewPipeline.imagePlan(for: request)

        XCTAssertEqual(plan.delayNanos, 250_000_000)
        XCTAssertEqual(plan.prefetchDelayNanos, 50_000_000)
        XCTAssertEqual(plan.targetWidthPixels, 1_280)
        XCTAssertEqual(plan.maxLongSidePixels, 12_000)
        XCTAssertEqual(plan.cacheKey, "hash-a|w1280")
    }

    func testImagePlanFallsBackToItemIDWhenContentHashIsMissing() {
        let itemID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let request = HistoryHoverPreviewPipeline.ImageRequest(
            itemID: itemID,
            contentHash: "",
            storageRef: nil,
            delay: 0,
            scale: 1,
            targetWidthPoints: 320,
            maxLongSidePixels: 8_000
        )

        let plan = HistoryHoverPreviewPipeline.imagePlan(for: request)

        XCTAssertEqual(plan.delayNanos, 0)
        XCTAssertEqual(plan.prefetchDelayNanos, 0)
        XCTAssertEqual(plan.cacheKey, "\(itemID.uuidString)|w320")
    }

    func testFilePlansPreserveKindSpecificCacheAndPrefetchPolicy() {
        let itemID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let imageInfo = FilePreviewSupport.previewInfo(from: "/tmp/picture.png", requireExists: false)!
        let otherInfo = FilePreviewSupport.previewInfo(from: "/tmp/document.pdf", requireExists: false)!

        let imagePlan = HistoryHoverPreviewPipeline.filePlan(
            for: HistoryHoverPreviewPipeline.FileRequest(
                itemID: itemID,
                contentHash: "file-hash",
                previewInfo: imageInfo,
                isMarkdown: false,
                delay: 0.1,
                scale: 2,
                targetWidthPoints: 500,
                targetHeightPoints: 300,
                maxLongSidePixels: 10_000
            )
        )
        let otherPlan = HistoryHoverPreviewPipeline.filePlan(
            for: HistoryHoverPreviewPipeline.FileRequest(
                itemID: itemID,
                contentHash: "file-hash",
                previewInfo: otherInfo,
                isMarkdown: false,
                delay: 0.1,
                scale: 2,
                targetWidthPoints: 500,
                targetHeightPoints: 300,
                maxLongSidePixels: 10_000
            )
        )

        XCTAssertTrue(imagePlan.shouldPrefetchImage)
        XCTAssertEqual(imagePlan.cacheKey, "file|file-hash|image|w1000")
        XCTAssertEqual(imagePlan.quickLookMaxSidePixels, 1_000)
        XCTAssertFalse(otherPlan.shouldPrefetchImage)
        XCTAssertEqual(otherPlan.cacheKey, "file|file-hash|other|w1000")
    }

    func testMarkdownFileRequestUsesSharedCacheKeyShape() {
        let itemID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let request = HistoryHoverPreviewPipeline.FileRequest(
            itemID: itemID,
            contentHash: "markdown-hash",
            previewInfo: FilePreviewSupport.previewInfo(from: "/tmp/source.md", requireExists: false)!,
            isMarkdown: true,
            delay: 0,
            scale: 1,
            targetWidthPoints: 500,
            targetHeightPoints: 400,
            maxLongSidePixels: 10_000
        )

        let markdownRequest = HistoryHoverPreviewPipeline.markdownFileRequest(fileRequest: request)

        XCTAssertEqual(markdownRequest.cacheKey, "file|markdown-hash")
        XCTAssertEqual(markdownRequest.url.path, "/tmp/source.md")
    }

    func testTextPreviewUsesCachedMarkdownCapabilityAndCachedHTMLMetrics() async {
        let item = makeItem(type: .text, contentHash: "cached-markdown", plainText: "# Title\n\nBody")
        let renderCacheKey = MarkdownRenderCacheKey.make(contentHash: item.contentHash, markdown: item.plainText)
        HistoryItemPresentationCache.shared.storeMarkdownExportCapability(true, for: item)
        MarkdownPreviewCache.shared.setHTML("<h1>Title</h1>", forKey: renderCacheKey)
        MarkdownPreviewCache.shared.setMetrics(
            MarkdownContentMetrics(size: CGSize(width: 12, height: 80), hasHorizontalOverflow: true),
            forKey: renderCacheKey
        )

        var events: [HistoryHoverPreviewPipeline.Event] = []
        await HistoryHoverPreviewPipeline.run(
            request: .text(HistoryHoverPreviewPipeline.textRequest(item: item, delay: 0)),
            isCurrent: { true },
            emit: { events.append($0) }
        )

        let textStates = events.compactMap { event -> HistoryHoverPreviewPipeline.TextPreviewState? in
            if case .text(let state) = event { return state }
            return nil
        }
        XCTAssertEqual(textStates.count, 2)
        XCTAssertEqual(textStates.first?.text, "# Title\n\nBody")
        XCTAssertTrue(textStates.first?.isMarkdown == true)
        XCTAssertNil(textStates.first?.markdownHTML)
        XCTAssertEqual(textStates.last?.markdownHTML, "<h1>Title</h1>")
        XCTAssertGreaterThan(textStates.last?.markdownContentSize?.width ?? 0, 12)
        XCTAssertEqual(presentedKinds(events), [.text])
    }

    func testSuppressionGatePreventsTextPreviewEvents() async {
        let item = makeItem(type: .text, contentHash: "suppressed", plainText: "plain")
        var events: [HistoryHoverPreviewPipeline.Event] = []

        await HistoryHoverPreviewPipeline.run(
            request: .text(HistoryHoverPreviewPipeline.textRequest(item: item, delay: 0)),
            isCurrent: { false },
            emit: { events.append($0) }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testImageCacheHitEmitsImageThenPopoverWithoutLoader() async throws {
        let itemID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let request = HistoryHoverPreviewPipeline.ImageRequest(
            itemID: itemID,
            contentHash: "cached-image",
            storageRef: nil,
            delay: 0,
            scale: 1,
            targetWidthPoints: 64,
            maxLongSidePixels: 1_024
        )
        let plan = HistoryHoverPreviewPipeline.imagePlan(for: request)
        let image = try XCTUnwrap(makeCGImage())
        HoverPreviewImageCache.shared.setImage(image, forKey: plan.cacheKey)

        var events: [HistoryHoverPreviewPipeline.Event] = []
        await HistoryHoverPreviewPipeline.run(
            request: .image(request),
            getImageData: {
                XCTFail("Image cache hit should not request backing data")
                return nil
            },
            isCurrent: { true },
            emit: { events.append($0) }
        )

        XCTAssertEqual(events.compactMap { event -> CGImage? in
            if case .image(let image) = event { return image }
            return nil
        }.count, 2)
        XCTAssertEqual(presentedKinds(events), [.image])
    }

    private func presentedKinds(_ events: [HistoryHoverPreviewPipeline.Event]) -> [HoverPreviewPopoverKind] {
        events.compactMap { event in
            if case .present(let kind) = event { return kind }
            return nil
        }
    }

    private func makeItem(
        type: ClipboardItemType,
        contentHash: String,
        plainText: String
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            note: nil,
            appBundleID: "com.scopy.tests",
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: plainText.utf8.count,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    private func makeCGImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }
}
