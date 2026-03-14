import Foundation
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryItemMarkdownExportControllerTests: XCTestCase {
    private let exportResolutionPercentUserDefaultsKey = "ScopyMarkdownExportResolutionPercent"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: exportResolutionPercentUserDefaultsKey)
        super.tearDown()
    }

    func testCanExportPNGForMarkdownTextItem() {
        let item = makeItem(type: .text, plainText: "# Title\n\n- bullet")

        XCTAssertTrue(HistoryItemMarkdownExportController.canExportPNG(item: item, filePreviewInfo: nil))
    }

    func testCanExportPNGRejectsPlainTextItem() {
        let item = makeItem(type: .text, plainText: "just a plain sentence")

        XCTAssertFalse(HistoryItemMarkdownExportController.canExportPNG(item: item, filePreviewInfo: nil))
    }

    func testCanExportPNGForMarkdownFilePreview() throws {
        let url = try createTemporaryFile(named: "note.md", contents: "# Title\n\nBody")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = makeItem(type: .file, plainText: url.path)
        let previewInfo = try XCTUnwrap(FilePreviewSupport.previewInfo(from: url.path))

        XCTAssertTrue(HistoryItemMarkdownExportController.canExportPNG(item: item, filePreviewInfo: previewInfo))
    }

    func testCanExportPNGRejectsNonMarkdownFilePreview() throws {
        let url = try createTemporaryFile(named: "note.txt", contents: "# Title\n\nBody")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = makeItem(type: .file, plainText: url.path)
        let previewInfo = try XCTUnwrap(FilePreviewSupport.previewInfo(from: url.path))

        XCTAssertFalse(HistoryItemMarkdownExportController.canExportPNG(item: item, filePreviewInfo: previewInfo))
    }

    func testLoadMarkdownSourceReturnsTextPayloadForMarkdownTextItem() async {
        let item = makeItem(type: .html, plainText: "# Title\n\nParagraph")

        let source = await HistoryItemMarkdownExportController.loadMarkdownSource(item: item, filePreviewInfo: nil)

        XCTAssertEqual(source, "# Title\n\nParagraph")
    }

    func testLoadMarkdownSourceReadsMarkdownFileContents() async throws {
        let expected = "# Heading\n\n- bullet"
        let url = try createTemporaryFile(named: "fixture.md", contents: expected)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = makeItem(type: .file, plainText: url.path)
        let previewInfo = try XCTUnwrap(FilePreviewSupport.previewInfo(from: url.path))

        let source = await HistoryItemMarkdownExportController.loadMarkdownSource(item: item, filePreviewInfo: previewInfo)

        XCTAssertEqual(source, expected)
    }

    func testDefaultResolutionScaleUsesStoredSetting() {
        UserDefaults.standard.set(150, forKey: exportResolutionPercentUserDefaultsKey)

        XCTAssertEqual(HistoryItemMarkdownExportController.defaultResolutionScale(), 1.5)
    }

    func testDefaultResolutionScaleFallsBackTo1xForInvalidStoredSetting() {
        UserDefaults.standard.set(125, forKey: exportResolutionPercentUserDefaultsKey)

        XCTAssertEqual(HistoryItemMarkdownExportController.defaultResolutionScale(), 1.0)
    }

    private func makeItem(type: ClipboardItemType, plainText: String) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: type,
            contentHash: UUID().uuidString,
            plainText: plainText,
            appBundleID: "com.test.app",
            createdAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: Date(timeIntervalSince1970: 2),
            isPinned: false,
            sizeBytes: plainText.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    private func createTemporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-markdown-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
