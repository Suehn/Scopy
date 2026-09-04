import AppKit
import SwiftUI
import XCTest
@testable import Scopy
@testable import ScopyKit

/// Renders history rows offscreen so a change to the row's view tree can be proved to leave the
/// pixels alone.
///
/// Simplifying the row is the only remaining lever on scroll CPU that does not change the design,
/// but "does not change the design" has to be checked rather than asserted, and this host cannot
/// take screenshots. `ImageRenderer` does not need Screen Recording: it rasterises the view
/// directly. Set `SCOPY_ROW_SNAPSHOT_DIR` to write the PNGs, then compare two runs with
/// `scripts/perf-scroll/compare_row_snapshots.py`.
@MainActor
final class HistoryRowPixelSnapshotTests: XCTestCase {
    private static let outputDirectory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["SCOPY_ROW_SNAPSHOT_DIR"] else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func testRendersEveryRowShape() throws {
        guard let directory = Self.outputDirectory else {
            throw XCTSkip("Set SCOPY_ROW_SNAPSHOT_DIR to capture row snapshots")
        }

        for shape in RowShape.allCases {
            let image = try XCTUnwrap(render(shape), "\(shape) produced no image")
            let png = try XCTUnwrap(pngData(from: image), "\(shape) produced no PNG")
            try png.write(to: directory.appendingPathComponent("\(shape.rawValue).png"))
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
        }
    }

    enum RowShape: String, CaseIterable {
        case text
        case textSelected
        case textPinned
        case longText
        case file
    }

    private func render(_ shape: RowShape) -> CGImage? {
        let renderer = ImageRenderer(content: row(for: shape).frame(width: 480))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func item(for shape: RowShape) -> ClipboardItemDTO {
        let text: String
        switch shape {
        case .longText:
            text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 12)
        case .file:
            text = "/tmp/example.txt"
        default:
            text = "hello clipboard"
        }
        return ClipboardItemDTO(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            type: shape == .file ? .file : .text,
            contentHash: "snapshot-\(shape.rawValue)",
            plainText: text,
            appBundleID: "com.apple.finder",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: shape == .textPinned,
            sizeBytes: text.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    @MainActor
    private func row(for shape: RowShape) -> some View {
        let coordinator = HistoryListInteractionCoordinator()
        return HistoryItemView(
            item: item(for: shape),
            isKeyboardSelected: shape == .textSelected,
            settings: .default,
            searchMatchContext: nil,
            onSelect: {},
            onSelectOptimizedForCodex: {},
            onSendViaAirDrop: {},
            onOpenContainingFolder: {},
            onHoverSelect: { _ in },
            onTogglePin: {},
            onDelete: {},
            onUpdateNote: { _ in true },
            onOptimizeImage: {
                ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: 0,
                    optimizedBytes: 0,
                    resultingContentHash: nil
                )
            },
            getImageData: { nil },
            markdownWebViewController: MarkdownPreviewWebViewController(),
            interactionCoordinator: coordinator,
            interactionSessionStore: HistoryItemInteractionSessionStore(),
            isContentRevisionCurrent: { _, _ in true },
            isImagePreviewPresented: false,
            isTextPreviewPresented: false,
            isFilePreviewPresented: false,
            isPreviewPinningActive: false,
            requestPopover: { _ in },
            requestPinPreview: { _, _, _ in },
            dismissOtherPopovers: {}
        )
    }
}
