import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemTextPreviewView: View {
    @ObservedObject var model: HoverPreviewModel
    let markdownWebViewController: MarkdownPreviewWebViewController?

    @Environment(AppState.self) private var appState

    @State private var exportTask: Task<Void, Never>?
    @State private var isExporting: Bool = false

    var body: some View {
        let maxWidth: CGFloat = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
        let maxHeight: CGFloat = HoverPreviewScreenMetrics.maxPopoverHeightPoints()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = ScopySpacing.md

        if let text = model.text {
            let fallbackWidth = HoverPreviewTextSizing.preferredWidth(
                for: text,
                font: font,
                padding: padding,
                maxWidth: maxWidth
            )
            let markdownMeasuredWidth = model.markdownContentSize?.width
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

            if model.isMarkdown, let html = model.markdownHTML {
                ZStack(alignment: .topTrailing) {
                    if let controller = markdownWebViewController {
                        ReusableMarkdownPreviewWebView(
                            controller: controller,
                            html: html,
                            shouldScroll: shouldScroll,
                            onContentSizeChange: { metrics in
                                guard model.markdownHTML == html else { return }
                                if let existing = model.markdownContentSize, existing.width > 0 {
                                    model.markdownContentSize = CGSize(width: existing.width, height: metrics.size.height)
                                } else {
                                    model.markdownContentSize = metrics.size
                                }
                                if metrics.hasHorizontalOverflow {
                                    model.markdownHasHorizontalOverflow = true
                                }
                            }
                        )
                    } else {
                        MarkdownPreviewWebView(
                            html: html,
                            shouldScroll: shouldScroll,
                            onContentSizeChange: { metrics in
                                guard model.markdownHTML == html else { return }
                                if let existing = model.markdownContentSize, existing.width > 0 {
                                    model.markdownContentSize = CGSize(width: existing.width, height: metrics.size.height)
                                } else {
                                    model.markdownContentSize = metrics.size
                                }
                                if metrics.hasHorizontalOverflow {
                                    model.markdownHasHorizontalOverflow = true
                                }
                            }
                        )
                    }

                    exportButton(html: html)
                        .padding(10)
                }
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

    @ViewBuilder
    private func exportButton(html: String) -> some View {
        Button {
            exportTask?.cancel()
            exportTask = Task { @MainActor in
                await exportRenderedMarkdownToClipboard(expectedHTML: html)
            }
        } label: {
            Group {
                if isExporting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: ScopyIcons.exportImage)
                        .font(.system(size: ScopySize.Icon.filter, weight: .medium))
                        .foregroundStyle(ScopyColors.mutedText)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Preview.ExportImage")
        .help("Copy rendered preview as PNG")
        .disabled(isExporting || markdownWebViewController == nil)
        .background(
            RoundedRectangle(cornerRadius: ScopySize.Corner.sm, style: .continuous)
                .fill(ScopyColors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScopySize.Corner.sm, style: .continuous)
                .stroke(ScopyColors.border.opacity(ScopySize.Opacity.subtle), lineWidth: ScopySize.Stroke.thin)
        )
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
        }
    }

    @MainActor
    private func exportRenderedMarkdownToClipboard(expectedHTML: String) async {
        guard let controller = markdownWebViewController else { return }
        guard model.markdownHTML == expectedHTML else { return }
        guard !isExporting else { return }

        isExporting = true
        defer { isExporting = false }

        do {
            let pngData = try await controller.makeLightSnapshotPNGForClipboard()
            try await appState.service.copyToClipboard(imagePNGData: pngData)
        } catch {
            ScopyLog.ui.error("Failed to export rendered preview image: \(error.localizedDescription, privacy: .private)")
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
