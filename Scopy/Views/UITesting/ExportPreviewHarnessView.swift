import AppKit
import SwiftUI

/// UI testing harness: renders the real Markdown preview view (including the overlay export button).
/// XCUITest will click near the top-right corner via coordinates (popover/overlay buttons can be hard to query reliably).
@MainActor
struct ExportPreviewHarnessView: View {
    @StateObject private var model: HoverPreviewModel
    private let controller = MarkdownPreviewWebViewController()

    init() {
        let markdown = Self.loadMarkdown()
        let m = HoverPreviewModel()
        m.text = markdown
        m.isMarkdown = true
        m.markdownHTML = MarkdownHTMLRenderer.render(markdown: markdown)
        m.markdownContentSize = nil
        m.markdownHasHorizontalOverflow = false
        m.isExporting = false
        m.exportSuccess = false
        m.exportFailed = false
        m.exportErrorMessage = nil
        _model = StateObject(wrappedValue: m)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HistoryItemTextPreviewView(model: model, markdownWebViewController: controller)
                .padding(12)

            // Presence marker for UI tests.
            Text("Export Harness")
                .opacity(0.001)
                .accessibilityIdentifier("UITest.ExportPreviewHarness.Title")
        }
        .frame(minWidth: 820, minHeight: 620)
        .accessibilityIdentifier("UITest.ExportPreviewHarness")
    }

    private static func loadMarkdown() -> String {
        if let path = ProcessInfo.processInfo.environment["SCOPY_UITEST_EXPORT_MARKDOWN_PATH"],
           !path.isEmpty,
           let s = try? String(contentsOfFile: path, encoding: .utf8),
           !s.isEmpty {
            return s
        }

        return """
        # SCOPY_UITEST_EXPORT_HARNESS

        - Inline math: $E = mc^2$

        ## Wide Table

        | very_long_header_col_01 | very_long_header_col_02 | very_long_header_col_03 | very_long_header_col_04 | very_long_header_col_05 | very_long_header_col_06 | very_long_header_col_07 | very_long_header_col_08 | very_long_header_col_09 | very_long_header_col_10 |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
        | aaaaaaaaaaaaaaaaaaaaa | bbbbbbbbbbbbbbbbbbbbb | ccccccccccccccccccccc | ddddddddddddddddddddd | eeeeeeeeeeeeeeeeeeeee | fffffffffffffffffffff | ggggggggggggggggggggg | hhhhhhhhhhhhhhhhhhhhh | iiiiiiiiiiiiiiiiiiiii | jjjjjjjjjjjjjjjjjjjjj |

        ## Long Content

        Paragraph 1: Ensure exported height is greater than a single viewport.

        Paragraph 2: More content to increase height.

        Paragraph 3: More content to increase height.

        Paragraph 4: More content to increase height.

        Paragraph 5: More content to increase height.
        """
    }
}

