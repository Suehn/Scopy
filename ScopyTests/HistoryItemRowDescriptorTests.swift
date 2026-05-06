import Foundation
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class HistoryItemRowDescriptorTests: XCTestCase {
    func testInjectedDependenciesDriveDisplayPreviewAndExportFields() throws {
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
        var exportReceivedPreviewPath: String?
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
                },
                canExportPNG: { received, filePreview in
                    XCTAssertEqual(received.id, item.id)
                    exportReceivedPreviewPath = filePreview?.path
                    return true
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
        XCTAssertTrue(descriptor.canExportPNG)
        XCTAssertTrue(descriptor.canShowFileThumbnail)
        XCTAssertTrue(descriptor.needsThumbnailHeight)
        XCTAssertEqual(descriptor.appIconBundleID, "com.scopy.source")
        XCTAssertEqual(exportReceivedPreviewPath, "/tmp/source.md")
    }

    func testTextItemDoesNotUseFileThumbnailHeightAndMirrorsAppIconBundleID() {
        let item = makeItem(type: .text, plainText: "plain text", appBundleID: "com.scopy.text")

        let descriptor = HistoryItemRowDescriptor(
            item: item,
            settings: settings(showThumbnails: true, thumbnailHeight: 64),
            dependencies: dependencies(
                title: "Text title",
                metadata: "Text metadata",
                filePreview: nil,
                canExportPNG: false
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
        XCTAssertFalse(descriptor.canExportPNG)
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

    func testMarkdownFilePreviewAndTextExportCapabilityStaySeparate() {
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
            dependencies: dependencies(filePreview: markdownPreview, canExportPNG: true)
        )

        let markdownText = makeItem(type: .text, plainText: "# Title")
        let textDescriptor = HistoryItemRowDescriptor(
            item: markdownText,
            settings: settings(),
            dependencies: dependencies(filePreview: nil, canExportPNG: true)
        )

        XCTAssertTrue(fileDescriptor.filePreviewIsMarkdown)
        XCTAssertEqual(fileDescriptor.filePreviewPath, "/tmp/note.md")
        XCTAssertTrue(fileDescriptor.canExportPNG)
        XCTAssertFalse(fileDescriptor.canShowFileThumbnail)

        XCTAssertFalse(textDescriptor.filePreviewIsMarkdown)
        XCTAssertNil(textDescriptor.filePreviewPath)
        XCTAssertTrue(textDescriptor.canExportPNG)
    }

    private func dependencies(
        title: String = "Title",
        metadata: String = "Metadata",
        filePreview: FilePreviewSummary? = nil,
        canExportPNG: Bool = false
    ) -> HistoryItemRowDescriptor.Dependencies {
        HistoryItemRowDescriptor.Dependencies(
            displayTexts: { _ in (title: title, metadata: metadata) },
            filePreview: { _ in filePreview },
            canExportPNG: { _, _ in canExportPNG }
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
        type: ClipboardItemType,
        plainText: String,
        appBundleID: String? = nil,
        thumbnailPath: String? = nil,
        storageRef: String? = nil
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: UUID(),
            type: type,
            contentHash: UUID().uuidString,
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
