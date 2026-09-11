import AppKit
import CoreGraphics
import XCTest
@testable import ScopyKit

/// A pinned preview is deliberately decoupled from the row that created it: it holds its own copy
/// of the rendered content so scrolling, row recycling and hovering other rows cannot disturb it,
/// and it closes only on an explicit action or when its item is gone.
@MainActor
final class PinnedPreviewControllerTests: XCTestCase {
    private var controller: PinnedPreviewController!

    override func setUp() async throws {
        controller = PinnedPreviewController()
    }

    override func tearDown() async throws {
        controller?.dismiss()
        controller = nil
    }

    // MARK: - Content hand-off

    func testAdoptedContentIsIndependentOfTheSourceModel() {
        let source = HoverPreviewModel()
        source.primeTextPreview(
            text: "# Title",
            isMarkdown: true,
            markdownHTML: "<h1>Title</h1>",
            markdownContentSize: CGSize(width: 400, height: 220),
            markdownHasHorizontalOverflow: false
        )

        let adopted = HoverPreviewModel()
        adopted.adoptRenderedContent(from: source)

        // The row is free to tear its own preview down the moment the pin happens.
        source.resetPreviewContent()

        XCTAssertEqual(adopted.text, "# Title")
        XCTAssertTrue(adopted.isMarkdown)
        XCTAssertEqual(adopted.markdownHTML, "<h1>Title</h1>")
        XCTAssertEqual(adopted.markdownContentSize, CGSize(width: 400, height: 220))
        XCTAssertNil(source.markdownHTML)
    }

    func testLiveRenderStampMovesAcrossSoThePinnedHostReusesTheCurrentNavigation() {
        let source = HoverPreviewModel()
        source.primeTextPreview(
            text: "body",
            isMarkdown: true,
            markdownHTML: "<p>body</p>",
            markdownContentSize: CGSize(width: 300, height: 100),
            markdownHasHorizontalOverflow: false
        )
        source.markMarkdownRenderSucceeded(for: "render-key")

        let adopted = HoverPreviewModel()
        adopted.adoptRenderedContent(from: source)

        XCTAssertTrue(
            adopted.isMarkdownRenderLive(for: "render-key"),
            "Pinning must not put the document back into a pending render state"
        )
    }

    // MARK: - Pin / dismiss

    func testPinIsRejectedWhenThereIsNothingRenderedYet() {
        controller.pin(
            item: Self.makeItem(),
            revision: Self.makeRevision(),
            kind: .text,
            filePreviewKind: nil,
            filePreviewPath: nil,
            source: HoverPreviewModel(),
            settingsViewModel: SettingsViewModel(service: MockClipboardService()),
            markdownWebViewController: MarkdownPreviewWebViewController()
        )

        XCTAssertFalse(controller.isPinned, "An empty preview has nothing to pin")
    }

    func testPinThenDismissClearsTheWindowState() {
        let item = Self.makeItem()
        pin(item: item)
        XCTAssertTrue(controller.isPinned)
        XCTAssertTrue(controller.isPinned(itemID: item.id))

        controller.dismiss()
        XCTAssertFalse(controller.isPinned)
        XCTAssertFalse(controller.isPinned(itemID: item.id))
    }

    func testMultipleWindowsHaveIndependentModelsAndCloseIndividually() throws {
        let first = Self.makeItem(), second = Self.makeItem()
        pin(item: first)
        pin(item: second)
        XCTAssertEqual(controller.previews.count, 2)
        let firstModel = try XCTUnwrap(controller.previews[first.id]?.model)
        let secondModel = try XCTUnwrap(controller.previews[second.id]?.model)
        firstModel.previewLayoutScalePercent = 200
        XCTAssertNil(secondModel.previewLayoutScalePercent)
        controller.dismiss(itemID: first.id)
        XCTAssertTrue(controller.isPinned(itemID: second.id))
        XCTAssertEqual(secondModel.text, second.plainText)
    }

    func testDeletionClosesOnlyTheAffectedWindow() {
        let first = Self.makeItem(), second = Self.makeItem()
        pin(item: first)
        pin(item: second)
        controller.reconcile(snapshot: Self.snapshot(deleted: [first.id]))
        XCTAssertFalse(controller.isPinned(itemID: first.id))
        XCTAssertTrue(controller.isPinned(itemID: second.id))
    }

    func testSavedWindowFrameFitsAfterDisplayChanges() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let saved = CGRect(x: 1900, y: -300, width: 2100, height: 1200)
        let fitted = PinnedPreviewController.fittedFrame(saved, in: screen)
        XCTAssertEqual(fitted, screen)
        let normal = CGRect(x: -1000, y: 100, width: 500, height: 600)
        XCTAssertEqual(PinnedPreviewController.fittedFrame(normal, in: screen), normal)
    }

    func testPinnedWindowChromeFitsNarrowAndWideContent() throws {
        let item = Self.makeItem()
        pin(item: item)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinnedPreviewPanel }.first { $0.isVisible })
        let host = try XCTUnwrap(panel.contentView)
        for width in [320, 1000, 320] {
            panel.setContentSize(CGSize(width: width, height: 400))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(host.bounds.width, CGFloat(width), accuracy: 1)
            XCTAssertEqual(host.bounds.height, panel.frame.height, accuracy: 1, "Content fills the titlebar area")
            XCTAssertTrue(panel.standardWindowButton(.closeButton)?.isHidden == true)

        }
    }

    func testPlainTextBeginsAtTheTopWithoutAToolbarRow() throws {
        pin(item: Self.makeItem())
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinnedPreviewPanel }.first { $0.isVisible })
        let host = try XCTUnwrap(panel.contentView)
        panel.setContentSize(CGSize(width: 640, height: 400))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func textScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
            return view.subviews.lazy.compactMap { textScrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(textScrollView(in: host))
        let contentFrame = scroll.convert(scroll.bounds, to: host)
        let topInset = host.isFlipped ? contentFrame.minY - host.bounds.minY : host.bounds.maxY - contentFrame.maxY
        XCTAssertEqual(topInset, 0, accuracy: 1, "Controls must overlay the document, not insert an empty header")
    }

    // MARK: - Reconciliation

    func testPinnedPreviewSurvivesAnUnrelatedItemsDeletion() {
        let item = Self.makeItem()
        pin(item: item)

        controller.reconcile(snapshot: Self.snapshot(deleted: [UUID()]))

        XCTAssertTrue(controller.isPinned, "Another row disappearing must not close the pinned preview")
    }

    func testPinnedPreviewClosesWhenItsItemIsDeleted() {
        let item = Self.makeItem()
        pin(item: item)

        controller.reconcile(snapshot: Self.snapshot(deleted: [item.id]))

        XCTAssertFalse(controller.isPinned)
    }

    func testPinnedPreviewClosesWhenItsPayloadIsReplaced() {
        let item = Self.makeItem()
        pin(item: item)

        let replaced = ClipboardItemDTO(
            id: item.id,
            type: .text,
            contentHash: "replacement-hash",
            plainText: "replacement",
            note: nil,
            appBundleID: nil,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: false,
            sizeBytes: 11,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil
        )
        controller.reconcile(
            snapshot: Self.snapshot(knownRevisions: [item.id: ClipboardItemContentRevision(item: replaced)])
        )

        XCTAssertFalse(controller.isPinned, "The window shows a snapshot; a superseded revision must not stay up")
    }

    func testPinnedPreviewClosesWhenClearRemovesIt() {
        let item = Self.makeItem()
        pin(item: item)

        controller.reconcile(
            snapshot: Self.snapshot(clearGeneration: 1, clearSurvivingItemIDs: [], survivorSetIsAuthoritative: true)
        )

        XCTAssertFalse(controller.isPinned)
    }

    func testPinnedPreviewSurvivesAClearItWasPinnedThrough() {
        let item = Self.makeItem()
        pin(item: item)

        controller.reconcile(
            snapshot: Self.snapshot(
                clearGeneration: 1,
                clearSurvivingItemIDs: [item.id],
                survivorSetIsAuthoritative: true
            )
        )

        XCTAssertTrue(controller.isPinned, "A pinned item that survived Clear All keeps its window")
    }

    // MARK: - Helpers

    private func pin(item: ClipboardItemDTO) {
        let source = HoverPreviewModel()
        source.primeTextPreview(
            text: item.plainText,
            isMarkdown: false,
            markdownHTML: nil,
            markdownContentSize: nil,
            markdownHasHorizontalOverflow: false
        )
        controller.pin(
            item: item,
            revision: ClipboardItemContentRevision(item: item),
            kind: .text,
            filePreviewKind: nil,
            filePreviewPath: nil,
            source: source,
            settingsViewModel: SettingsViewModel(service: MockClipboardService()),
            markdownWebViewController: MarkdownPreviewWebViewController()
        )
    }

    private static func makeItem() -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: "pinned-hash",
            plainText: "pinned content",
            note: nil,
            appBundleID: nil,
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: 14,
            fileSizeBytes: nil,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    private static func makeRevision() -> ClipboardItemContentRevision {
        ClipboardItemContentRevision(item: makeItem())
    }

    private static func snapshot(
        knownRevisions: [UUID: ClipboardItemContentRevision] = [:],
        deleted: Set<UUID> = [],
        clearGeneration: UInt64 = 0,
        clearSurvivingItemIDs: Set<UUID> = [],
        survivorSetIsAuthoritative: Bool = true,
        deletionEvictionGeneration: UInt64 = 0
    ) -> HistoryContentRevisionReconciliationSnapshot {
        HistoryContentRevisionReconciliationSnapshot(
            knownRevisionsByItemID: knownRevisions,
            deletedItemIDs: deleted,
            clearGeneration: clearGeneration,
            clearSurvivingItemIDs: clearSurvivingItemIDs,
            clearSurvivorSetIsAuthoritative: survivorSetIsAuthoritative,
            deletionEvictionGeneration: deletionEvictionGeneration
        )
    }
}
