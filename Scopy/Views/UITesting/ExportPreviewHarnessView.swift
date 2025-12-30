import AppKit
import SwiftUI
import ScopyKit

/// UI testing harness: renders the real Markdown preview view (including the overlay export button).
/// XCUITest will click near the top-right corner via coordinates (popover/overlay buttons can be hard to query reliably).
@MainActor
struct ExportPreviewHarnessView: View {
    @StateObject private var model: HoverPreviewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var isExporting = false
    private let controller = MarkdownPreviewWebViewController()

    init() {
        let markdown = Self.loadMarkdown()
        let htmlOverride = Self.loadHTMLOverride()
        let m = HoverPreviewModel()
        if let htmlOverride, !htmlOverride.isEmpty {
            // Keep a wide fallback so the export button stays near the top-right of the harness window.
            m.text = String(repeating: "X", count: 260)
        } else {
            m.text = markdown
        }
        // Avoid hosting a live WKWebView inside the export harness: UI testing + multiple WebViews can be flaky.
        // Export still uses the offscreen export pipeline via `markdownHTML`.
        m.isMarkdown = false
        m.markdownHTML = htmlOverride ?? MarkdownHTMLRenderer.render(markdown: markdown)
        m.markdownContentSize = nil
        m.markdownHasHorizontalOverflow = false
        m.isExporting = false
        m.exportSuccess = false
        m.exportFailed = false
        m.exportErrorMessage = nil
        _model = StateObject(wrappedValue: m)
        _settingsViewModel = State(initialValue: SettingsViewModel(service: ClipboardServiceFactory.create(useMock: true)))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HistoryItemTextPreviewView(model: model, markdownWebViewController: controller)
                .environment(settingsViewModel)
                .padding(12)

            // Presence marker for UI tests.
            Text("Export Harness")
                .opacity(0.001)
                .accessibilityIdentifier("UITest.ExportPreviewHarness")

            // Reliable export trigger for UI tests (overlay buttons on top of WKWebView are hard to click deterministically).
            Button("Export") { exportNow() }
                .buttonStyle(.borderless)
                // Keep this visible and well-positioned: XCUITest can treat near-transparent elements as not hittable.
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                .cornerRadius(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)
                .contentShape(Rectangle())
                .disabled(isExporting)
                .accessibilityIdentifier("UITest.ExportPreviewHarness.ExportNow")
        }
        .frame(minWidth: 820, minHeight: 620)
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

    private static func loadHTMLOverride() -> String? {
        if let path = ProcessInfo.processInfo.environment["SCOPY_UITEST_EXPORT_HTML_PATH"],
           !path.isEmpty,
           let s = try? String(contentsOfFile: path, encoding: .utf8),
           !s.isEmpty {
            return s
        }
        return nil
    }

    private func exportNow() {
        guard !isExporting else { return }
        guard let html = model.markdownHTML, !html.isEmpty else { return }

        isExporting = true
        let scale = Self.exportResolutionScaleFromEnvironment()
        MarkdownExportService.exportToPNGClipboard(
            html: html,
            targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels,
            resolutionScale: scale,
            pngquantOptions: nil
        ) { _ in
            Task { @MainActor in
                self.isExporting = false
            }
        }
    }

    private static func exportResolutionScaleFromEnvironment() -> CGFloat {
        let raw = ProcessInfo.processInfo.environment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"]
        guard let raw else { return 1 }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }

        let lowered = trimmed.lowercased()
        let noSuffix: String
        if lowered.hasSuffix("x") {
            noSuffix = String(lowered.dropLast())
        } else {
            noSuffix = lowered
        }

        if let percent = Int(noSuffix), percent >= 50 {
            return max(0.5, min(4, CGFloat(percent) / 100))
        }
        if let multiplier = Double(noSuffix), multiplier > 0 {
            return max(0.5, min(4, CGFloat(multiplier)))
        }

        return 1
    }
}
