import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemTextPreviewView: View {
    @Environment(SettingsViewModel.self) private var settingsViewModel
    @ObservedObject var model: HoverPreviewModel
    let markdownWebViewController: MarkdownPreviewWebViewController?
    let showMarkdownPlaceholder: Bool

    init(
        model: HoverPreviewModel,
        markdownWebViewController: MarkdownPreviewWebViewController?,
        showMarkdownPlaceholder: Bool = false
    ) {
        self._model = ObservedObject(wrappedValue: model)
        self.markdownWebViewController = markdownWebViewController
        self.showMarkdownPlaceholder = showMarkdownPlaceholder
    }

    // Export success feedback reset task
    @State private var exportSuccessResetTask: Task<Void, Never>?

    private static let minSaneMarkdownMeasuredWidth: CGFloat = 40
    private static let markdownWidthGrowThreshold: CGFloat = 40

    var body: some View {
        let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
        let maxHeight: CGFloat = HoverPreviewScreenMetrics.maxPopoverHeightPoints()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = ScopySpacing.md

        Group {
            if let text = model.text {
                let fallbackWidth = HoverPreviewTextSizing.preferredWidth(
                    for: text,
                    font: font,
                    padding: padding,
                    maxWidth: maxWidth
                )
                let markdownMeasuredWidth: CGFloat? = {
                    guard let w = model.markdownContentSize?.width else { return nil }
                    guard w.isFinite, w >= Self.minSaneMarkdownMeasuredWidth else { return nil }
                    if fallbackWidth.isFinite, fallbackWidth > 0, w < fallbackWidth * 0.5 { return nil }
                    return w
                }()
                let width: CGFloat = {
                    if model.isMarkdown {
                        // Prefer shrink-to-fit for small Markdown payloads, while snapping to max width when near-max or when
                        // horizontal scrolling is detected (e.g. long KaTeX / code blocks).
                        let measured = markdownMeasuredWidth ?? fallbackWidth
                        let desired = max(1, min(maxWidth, ceil(measured + 2)))
                        if model.markdownHasHorizontalOverflow { return maxWidth }
                        return (desired >= maxWidth * 0.92) ? maxWidth : desired
                    }
                    return fallbackWidth
                }()

                let measuredTextHeight: CGFloat = HoverPreviewTextSizing.preferredTextHeight(
                    for: text,
                    font: font,
                    contentWidth: max(1, width - padding * 2),
                    maxHeight: maxHeight
                )
                let textContentHeight = measuredTextHeight + padding * 2

                // Add a small buffer to avoid occasional off-by-a-few-pixels scroll for very small content.
                let markdownMeasuredHeight = model.markdownContentSize?.height
                let contentHeight = (model.isMarkdown ? (markdownMeasuredHeight ?? textContentHeight) : textContentHeight) + 4
                let clampedHeight = min(maxHeight, max(1, contentHeight))
                let shouldScroll = contentHeight > maxHeight

                if model.isMarkdown, model.markdownHTML == nil, showMarkdownPlaceholder {
                    ProgressView()
                        .frame(width: width, height: clampedHeight)
                } else if model.isMarkdown, let html = model.markdownHTML {
                    ZStack(alignment: .topTrailing) {
                        if let controller = markdownWebViewController {
                            ReusableMarkdownPreviewWebView(
                                controller: controller,
                                html: html,
                                shouldScroll: shouldScroll,
                                onContentSizeChange: { metrics in
                                    guard model.markdownHTML == html else { return }
                                    let newWidth = metrics.size.width
                                    let newHeight = metrics.size.height
                                    if let existing = model.markdownContentSize {
                                        let existingWidth = existing.width
                                        var width = existingWidth
                                        if existingWidth < Self.minSaneMarkdownMeasuredWidth,
                                           newWidth > existingWidth
                                        {
                                            width = newWidth
                                        } else if newWidth > existingWidth + Self.markdownWidthGrowThreshold {
                                            width = newWidth
                                        } else if existingWidth <= 0, newWidth > 0 {
                                            width = newWidth
                                        }
                                        model.markdownContentSize = CGSize(width: width, height: newHeight)
                                    } else {
                                        model.markdownContentSize = metrics.size
                                    }
                                    if metrics.hasHorizontalOverflow {
                                        model.markdownHasHorizontalOverflow = true
                                    }
                                }
                            )
                            .frame(width: width, height: clampedHeight)
                        } else {
                            MarkdownPreviewWebView(
                                html: html,
                                shouldScroll: shouldScroll,
                                onContentSizeChange: { metrics in
                                    guard model.markdownHTML == html else { return }
                                    let newWidth = metrics.size.width
                                    let newHeight = metrics.size.height
                                    if let existing = model.markdownContentSize {
                                        let existingWidth = existing.width
                                        var width = existingWidth
                                        if existingWidth < Self.minSaneMarkdownMeasuredWidth,
                                           newWidth > existingWidth
                                        {
                                            width = newWidth
                                        } else if newWidth > existingWidth + Self.markdownWidthGrowThreshold {
                                            width = newWidth
                                        } else if existingWidth <= 0, newWidth > 0 {
                                            width = newWidth
                                        }
                                        model.markdownContentSize = CGSize(width: width, height: newHeight)
                                    } else {
                                        model.markdownContentSize = metrics.size
                                    }
                                    if metrics.hasHorizontalOverflow {
                                        model.markdownHasHorizontalOverflow = true
                                    }
                                }
                            )
                            .frame(width: width, height: clampedHeight)
                        }

                        exportButton()
                            .padding(ScopySpacing.sm)
                    }
                    .accessibilityIdentifier("History.Preview.Container")
                    .accessibilityElement(children: .contain)
                    .frame(width: width, height: clampedHeight)
                } else {
                    HoverPreviewTextView(text: text, font: font, width: width, shouldScroll: shouldScroll)
                        .frame(width: width, height: clampedHeight)
                }
            } else {
                ProgressView()
                    .frame(width: maxWidth, height: min(maxHeight, 160))
            }
        }
        .accessibilityIdentifier("History.Preview.Text")
        .accessibilityElement(children: .contain)
    }

    // MARK: - Export Button

    @ViewBuilder
    private func exportButton() -> some View {
        Button(action: { exportToPNG() }) {
            Group {
                if model.exportSuccess {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                } else if model.exportFailed {
                    Image(systemName: "xmark")
                        .foregroundColor(.red)
                } else if model.isExporting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: ScopyIcons.image)
                        .foregroundColor(ScopyColors.mutedText)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 24)
        }
        .accessibilityIdentifier("History.Preview.ExportButton")
        .accessibilityLabel("Export PNG")
        .accessibilityValue(model.exportSuccess ? "success" : (model.exportFailed ? "failed" : (model.isExporting ? "exporting" : "idle")))
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(ScopyColors.secondaryBackground.opacity(0.9))
        )
        .overlay(
            Circle()
                .stroke(ScopyColors.separator.opacity(0.5), lineWidth: 0.5)
        )
        .help(exportButtonHelpText)
        .disabled(model.isExporting)
        .onDisappear {
            exportSuccessResetTask?.cancel()
            exportSuccessResetTask = nil
            model.exportSuccess = false
            model.exportSuccessMessage = nil
            model.exportFailed = false
            model.exportErrorMessage = nil
        }
    }

    private var exportButtonHelpText: String {
        if model.isExporting { return "Exporting PNG…" }
        if model.exportSuccess, let message = model.exportSuccessMessage, !message.isEmpty {
            return message
        }
        if model.exportFailed, let message = model.exportErrorMessage, !message.isEmpty {
            return "Export failed: \(message)"
        }
        return "Export as PNG to clipboard"
    }

    private func exportToPNG() {
        guard !model.isExporting else { return }
        guard let html = model.markdownHTML else { return }

        let settings = settingsViewModel.settings
        let pngquantOptions: PngquantService.Options? = {
            guard settings.pngquantMarkdownExportEnabled else { return nil }
            return PngquantService.Options(
                binaryPath: settings.pngquantBinaryPath,
                qualityMin: settings.pngquantMarkdownExportQualityMin,
                qualityMax: settings.pngquantMarkdownExportQualityMax,
                speed: settings.pngquantMarkdownExportSpeed,
                colors: settings.pngquantMarkdownExportColors
            )
        }()

        model.isExporting = true
        model.exportSuccess = false
        model.exportSuccessMessage = nil
        model.exportFailed = false
        model.exportErrorMessage = nil
        exportSuccessResetTask?.cancel()

        MarkdownExportService.exportToPNGClipboard(
            html: html,
            targetWidthPixels: 1080,
            pngquantOptions: pngquantOptions
        ) { result in
            Task { @MainActor in
                model.isExporting = false

                switch result {
                case .success(let stats):
                    model.exportSuccess = true
                    if let percent = stats.percentSaved {
                        if percent > 0 {
                            model.exportSuccessMessage = "Exported PNG (pngquant -\(percent)%)"
                        } else {
                            model.exportSuccessMessage = "Exported PNG (pngquant no change)"
                        }
                    } else {
                        model.exportSuccessMessage = "Exported PNG"
                    }
                    model.exportErrorMessage = nil
                    // Reset success state after 1.5 seconds
                    exportSuccessResetTask = Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            model.exportSuccess = false
                            model.exportSuccessMessage = nil
                        }
                    }
                case .failure(let error):
                    model.exportFailed = true
                    model.exportErrorMessage = error.localizedDescription
                    ScopyLog.ui.error("Export failed: \(error.localizedDescription, privacy: .public)")
                    exportSuccessResetTask = Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            model.exportFailed = false
                            model.exportErrorMessage = nil
                        }
                    }
                }
            }
        }
    }
}

private struct HoverPreviewTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let width: CGFloat
    let shouldScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = shouldScroll
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: ScopySpacing.md, height: ScopySpacing.md)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        context.coordinator.scrollbarAutoHider.attach(to: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        nsView.hasVerticalScroller = shouldScroll
        context.coordinator.scrollbarAutoHider.attach(to: nsView)
        context.coordinator.scrollbarAutoHider.applyHiddenState()

        let availableWidth = max(1, width)
        if context.coordinator.lastWidth != availableWidth {
            context.coordinator.lastWidth = availableWidth
            textView.frame.size.width = availableWidth
            if let textContainer = textView.textContainer {
                let insets = textView.textContainerInset
                textContainer.containerSize = NSSize(
                    width: max(1, availableWidth - insets.width * 2),
                    height: .greatestFiniteMagnitude
                )
            }
        }

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var lastText: String = ""
        var lastWidth: CGFloat = 0
        let scrollbarAutoHider = ScrollbarAutoHider()
    }
}
