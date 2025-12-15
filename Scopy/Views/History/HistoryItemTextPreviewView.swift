import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemTextPreviewView: View {
    @ObservedObject var model: HoverPreviewModel

    var body: some View {
        let maxWidth: CGFloat = ScopySize.Width.previewMax
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
            let width = max(1, min(maxWidth, ceil(markdownMeasuredWidth ?? fallbackWidth)))

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
                MarkdownPreviewWebView(
                    html: html,
                    shouldScroll: shouldScroll,
                    onContentSizeChange: { size in
                        if let existing = model.markdownContentSize,
                           abs(existing.width - size.width) < 1,
                           abs(existing.height - size.height) < 1
                        {
                            return
                        }
                        model.markdownContentSize = size
                    }
                )
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
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        nsView.hasVerticalScroller = shouldScroll

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
    }
}
