import Foundation
import XCTest
@testable import Scopy
@testable import ScopyKit

@MainActor
final class PreparedMarkdownDocumentTests: XCTestCase {
    func testEnrichmentArrivingBeforePresentationCannotRelabelPreparedHTML() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-prepared-document-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkEnrichmentStore(directory: directory)
        let source = "# News \(UUID().uuidString)\n\n[Example](https://example.com/story?utm_source=chatgpt.com)"
        let prepared = await PreparedMarkdownDocument.prepare(source: source, layoutScale: .percent100, store: store)
        let payload = LinkEnrichmentPayload(
            version: LinkEnrichmentPayload.formatVersion,
            fetchedAt: Date(),
            entries: ["https://example.com/story?utm_source=chatgpt.com": .init(title: "Frozen article title")]
        )

        // Another preview finishes enrichment while this document waits for its hover delay.
        await store.write(payload, forContentKey: prepared.contentKey)
        let model = HoverPreviewModel()
        model.primeTextPreview(content: .markdown(prepared))
        let presented = try XCTUnwrap(model.markdownDocument)
        XCTAssertNil(presented.context.linkEnrichment)
        XCTAssertEqual(presented.renderKey, prepared.renderKey)
        XCTAssertEqual(presented.html, MarkdownHTMLDocumentBuilder.document(source: source, context: prepared.context))

        // The first mounted view refresh also catches notifications sent before it subscribed.
        let refreshed = await presented.refreshed(layoutScale: .percent100, store: store)
        model.setMarkdownDocumentAwaitingLiveRender(refreshed)
        XCTAssertEqual(model.markdownDocument?.context.linkEnrichment, payload)
        XCTAssertNotEqual(refreshed.renderKey, presented.renderKey)
        XCTAssertNotEqual(refreshed.html, presented.html)
        XCTAssertEqual(refreshed.html, MarkdownHTMLDocumentBuilder.document(source: source, context: refreshed.context))
    }

    func testPinAndExportScaleKeepTheDisplayedSnapshotAfterStoreChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-prepared-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkEnrichmentStore(directory: directory)
        let source = "# Frozen \(UUID().uuidString)"
        let prepared = await PreparedMarkdownDocument.prepare(source: source, layoutScale: .percent100, store: store)
        let hover = HoverPreviewModel()
        hover.primeTextPreview(content: .markdown(prepared))
        hover.markMarkdownRenderSucceeded(for: prepared.renderKey)
        let pinned = HoverPreviewModel()
        pinned.adoptRenderedContent(from: hover)
        hover.resetPreviewContent()

        await store.write(
            .init(version: LinkEnrichmentPayload.formatVersion, fetchedAt: Date(), entries: ["https://example.com": .init(title: "Later")]),
            forContentKey: prepared.contentKey
        )
        let captured = try XCTUnwrap(pinned.markdownDocument)
        let export = await captured.withLayoutScale(.percent125)
        XCTAssertEqual(captured.renderKey, prepared.renderKey)
        XCTAssertTrue(pinned.isMarkdownRenderLive(for: prepared.renderKey))
        XCTAssertNil(hover.textContent, "Closing releases the entire source/context/document value")
        XCTAssertEqual(export.source, prepared.source)
        XCTAssertEqual(export.context.linkEnrichment, prepared.context.linkEnrichment)
        XCTAssertEqual(export.context.layoutScale, .percent125)
        XCTAssertEqual(export.html, MarkdownHTMLDocumentBuilder.document(source: source, context: export.context))
        XCTAssertNotEqual(export.renderKey, prepared.renderKey)
    }
}
