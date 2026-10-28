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

    func testAdoptedContentIsIndependentOfTheSourceModel() async {
        let source = HoverPreviewModel()
        let document = await PreparedMarkdownDocument.prepare(source: "# Title", layoutScale: .percent100)
        source.primeTextPreview(
            content: .markdown(document),
            markdownContentSize: CGSize(width: 400, height: 220),
            markdownHasHorizontalOverflow: false
        )

        let adopted = HoverPreviewModel()
        adopted.adoptRenderedContent(from: source)

        // The row is free to tear its own preview down the moment the pin happens.
        source.resetPreviewContent()

        XCTAssertEqual(adopted.text, "# Title")
        XCTAssertTrue(adopted.isMarkdown)
        XCTAssertEqual(adopted.markdownDocument?.html, document.html)
        XCTAssertEqual(adopted.markdownDocument?.renderKey, document.renderKey)
        XCTAssertEqual(adopted.markdownContentSize, CGSize(width: 400, height: 220))
        XCTAssertNil(source.markdownDocument)
        XCTAssertNil(source.textContent)
    }

    func testLiveRenderStampMovesAcrossSoThePinnedHostReusesTheCurrentNavigation() async {
        let source = HoverPreviewModel()
        let document = await PreparedMarkdownDocument.prepare(source: "body", layoutScale: .percent100)
        source.primeTextPreview(
            content: .markdown(document),
            markdownContentSize: CGSize(width: 300, height: 100),
            markdownHasHorizontalOverflow: false
        )
        source.markMarkdownRenderSucceeded(for: document.renderKey)

        let adopted = HoverPreviewModel()
        adopted.adoptRenderedContent(from: source)

        XCTAssertTrue(
            adopted.isMarkdownRenderLive(for: document.renderKey),
            "Pinning must not put the document back into a pending render state"
        )
    }

    // MARK: - Pin / dismiss

    func testSnapshotIsRejectedWhenThereIsNothingRenderedYet() {
        let preview = PinnedPreview(
            item: Self.makeItem(),
            revision: Self.makeRevision(),
            kind: .text,
            filePreviewKind: nil,
            filePreviewPath: nil,
            source: HoverPreviewModel(),
            markdownWebViewController: nil
        )

        XCTAssertNil(preview, "An empty preview has nothing to pin")
    }

    func testPinThenDismissClearsTheWindowState() {
        let item = Self.makeItem()
        pin(item: item)
        XCTAssertTrue(controller.isPinned(itemID: item.id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        controller.dismiss()
        XCTAssertFalse(controller.isPinned(itemID: item.id))
    }

    func testPinKeepsOneSnapshotAndReleasesItsTransferredWebViewOnClose() throws {
        let item = Self.makeItem()
        let source = HoverPreviewModel()
        source.primeTextPreview(content: .plain(item.plainText))
        let webViewController = MarkdownPreviewWebViewController()
        let ownerID = UUID()
        webViewController.beginOwnership(ownerID)
        let preview = try XCTUnwrap(PinnedPreview(
            item: item, revision: ClipboardItemContentRevision(item: item), kind: .text,
            filePreviewKind: nil, filePreviewPath: nil, source: source,
            markdownWebViewController: webViewController
        ))
        source.resetPreviewContent()
        XCTAssertTrue(controller.pin(preview, settingsViewModel: SettingsViewModel(service: MockClipboardService())))
        XCTAssertTrue(controller.previewsForTesting[item.id]?.model === preview.model)
        XCTAssertEqual(preview.model.text, item.plainText)

        controller.dismiss(itemID: item.id)
        XCTAssertFalse(webViewController.owns(ownerID), "Close releases the bridge before deferred SwiftUI dismantling")
    }

    func testInvalidationDuringHandoffPreventsTheWindowFromOpening() async throws {
        let item = Self.makeItem()
        let source = HoverPreviewModel()
        source.primeTextPreview(content: .plain(item.plainText))
        let preview = try XCTUnwrap(PinnedPreview(
            item: item, revision: ClipboardItemContentRevision(item: item), kind: .text,
            filePreviewKind: nil, filePreviewPath: nil, source: source,
            markdownWebViewController: nil
        ))
        let invalidations = [
            Self.snapshot(deleted: [item.id]),
            Self.snapshot(knownRevisions: [item.id: ClipboardItemContentRevision(
                item: Self.makeItem(id: item.id, contentHash: "replacement")
            )]),
            Self.snapshot(clearGeneration: 1, clearSurvivingItemIDs: [])
        ]
        for snapshot in invalidations {
            let presented = expectation(description: "invalidated pin must not present")
            presented.isInverted = true
            XCTAssertTrue(controller.pin(
                preview, settingsViewModel: SettingsViewModel(service: MockClipboardService()),
                onPresented: { presented.fulfill() }
            ))
            controller.reconcile(snapshot: snapshot)
            XCTAssertFalse(controller.isPinned(itemID: item.id))
            await fulfillment(of: [presented], timeout: 0.05)
        }
        XCTAssertFalse(NSApp.windows.contains { $0 is PinnedPreviewPanel && $0.isVisible })
    }

    func testMultipleWindowsHaveIndependentModelsAndCloseIndividually() throws {
        let first = Self.makeItem(), second = Self.makeItem()
        pin(item: first)
        pin(item: second)
        XCTAssertEqual(controller.previewsForTesting.count, 2)
        let firstModel = try XCTUnwrap(controller.previewsForTesting[first.id]?.model)
        let secondModel = try XCTUnwrap(controller.previewsForTesting[second.id]?.model)
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

    func testLateCloseCallbackCannotCloseAReplacementWindow() throws {
        let item = Self.makeItem()
        pin(item: item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let oldPanel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinnedPreviewPanel }.first { $0.isVisible })
        let oldClose = try XCTUnwrap(oldPanel.onCloseRequested)
        controller.dismiss(itemID: item.id)

        pin(item: item)
        oldClose()

        XCTAssertTrue(controller.isPinned(itemID: item.id), "A callback belongs to one window, not every pin of that item")
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
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

        XCTAssertTrue(controller.isPinned(itemID: item.id), "Another row disappearing must not close the pinned preview")
    }

    func testPinnedPreviewClosesWhenItsItemIsDeleted() {
        let item = Self.makeItem()
        pin(item: item)

        controller.reconcile(snapshot: Self.snapshot(deleted: [item.id]))

        XCTAssertFalse(controller.isPinned(itemID: item.id))
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

        XCTAssertFalse(controller.isPinned(itemID: item.id), "The window shows a snapshot; a superseded revision must not stay up")
    }

    func testPinnedPreviewClosesWhenClearRemovesIt() {
        let item = Self.makeItem()
        pin(item: item)

        controller.reconcile(
            snapshot: Self.snapshot(clearGeneration: 1, clearSurvivingItemIDs: [], survivorSetIsAuthoritative: true)
        )

        XCTAssertFalse(controller.isPinned(itemID: item.id))
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

        XCTAssertTrue(controller.isPinned(itemID: item.id), "A pinned item that survived Clear All keeps its window")
    }

    /// With history at its max-items limit every capture deletes a row, so once the tombstone
    /// registry is full each deletion evicts its oldest tombstone. Evicting tombstones this window
    /// already applied hides nothing from it and must not close it.
    func testPinnedPreviewSurvivesEvictionOfTombstonesItAlreadyApplied() async {
        let service = TestMockClipboardService()
        service.setItemCount(2)
        let appState = AppState.forTesting(service: service)
        addTeardownBlock { await appState.stop() }
        let viewModel = appState.historyViewModel
        await viewModel.load()
        let item = viewModel.items[0]
        pin(item: item)
        controller.reconcile(snapshot: viewModel.contentRevisionReconciliationSnapshot)

        let fullRegistry = (0..<HistoryViewModel.knownContentRevisionCapacity).map { _ in UUID() }
        await viewModel.handleEvent(.itemsRemoved(fullRegistry))
        controller.reconcile(snapshot: viewModel.contentRevisionReconciliationSnapshot)
        for _ in 0..<3 {
            await viewModel.handleEvent(.itemDeleted(UUID()))
            let snapshot = viewModel.contentRevisionReconciliationSnapshot
            XCTAssertGreaterThan(snapshot.newestEvictedDeletionStamp, 0, "The deletion evicted a tombstone")
            controller.reconcile(snapshot: snapshot)
            XCTAssertTrue(controller.isPinned(itemID: item.id))
        }

        await viewModel.handleEvent(.itemDeleted(item.id))
        controller.reconcile(snapshot: viewModel.contentRevisionReconciliationSnapshot)
        XCTAssertFalse(controller.isPinned(itemID: item.id), "Deleting the item itself still closes it")
    }

    // MARK: - Helpers

    private func pin(item: ClipboardItemDTO) {
        let source = HoverPreviewModel()
        source.primeTextPreview(
            content: .plain(item.plainText),
            markdownContentSize: nil,
            markdownHasHorizontalOverflow: false
        )
        let preview = PinnedPreview(
            item: item,
            revision: ClipboardItemContentRevision(item: item),
            kind: .text,
            filePreviewKind: nil,
            filePreviewPath: nil,
            source: source,
            markdownWebViewController: nil
        )!
        XCTAssertTrue(controller.pin(preview, settingsViewModel: SettingsViewModel(service: MockClipboardService())))
    }

    private static func makeItem(id: UUID = UUID(), contentHash: String = "pinned-hash") -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: .text,
            contentHash: contentHash,
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
        survivorSetIsAuthoritative: Bool = true
    ) -> HistoryContentRevisionReconciliationSnapshot {
        HistoryContentRevisionReconciliationSnapshot(
            knownRevisionsByItemID: knownRevisions,
            deletedItemIDs: deleted,
            clearGeneration: clearGeneration,
            clearSurvivingItemIDs: clearSurvivingItemIDs,
            clearSurvivorSetIsAuthoritative: survivorSetIsAuthoritative,
            stamp: 0,
            newestEvictedDeletionStamp: 0
        )
    }
}
