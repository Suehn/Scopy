import AppKit
import ScopyKit
import SwiftUI

/// Contents of the pinned preview window.
///
/// The same preview views the hover popover uses, laid out against the window's live content size
/// instead of the screen-derived popover budget, so resizing the window reflows the document
/// through the existing fit-to-width path rather than a second renderer.
struct PinnedPreviewWindowView: View {
    /// Header height, used by the controller to size the first frame around the measured content.
    static let chromeHeight: CGFloat = 29

    let preview: PinnedPreview
    let markdownWebViewController: MarkdownPreviewWebViewController
    let onKeepsOnTopChange: (Bool) -> Void
    let onDismiss: () -> Void

    /// Owned here so the header re-renders on toggle; the controller applies the window level.
    @State private var keepsOnTop: Bool

    init(
        preview: PinnedPreview,
        markdownWebViewController: MarkdownPreviewWebViewController,
        initialKeepsOnTop: Bool,
        onKeepsOnTopChange: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.preview = preview
        self.markdownWebViewController = markdownWebViewController
        self.onKeepsOnTopChange = onKeepsOnTopChange
        self.onDismiss = onDismiss
        _keepsOnTop = State(initialValue: initialKeepsOnTop)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .background(ScopyColors.separator.opacity(ScopySize.Opacity.light))
            GeometryReader { proxy in
                previewContent
                    .environment(\.hoverPreviewSizeBudget, .window(proxy.size))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        // `contain` keeps the header controls individually addressable; without it the window
        // identifier is inherited by every descendant and shadows theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PinnedPreview.Window")
    }

    private var header: some View {
        HStack(spacing: ScopySpacing.sm) {
            Image(systemName: "pin.fill")
                .font(.system(size: ScopySize.Icon.xs))
                .foregroundStyle(ScopyColors.accent)
            Text(title)
                .font(ScopyTypography.caption)
                .foregroundStyle(ScopyColors.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: ScopySpacing.sm)
            Button {
                keepsOnTop.toggle()
                onKeepsOnTopChange(keepsOnTop)
            } label: {
                Image(systemName: keepsOnTop ? "macwindow.on.rectangle" : "macwindow")
                    .font(.system(size: ScopySize.Icon.xs))
            }
            .buttonStyle(.plain)
            .foregroundStyle(keepsOnTop ? ScopyColors.accent : ScopyColors.mutedText)
            .help(keepsOnTop ? "Keep above other apps (on)" : "Keep above other apps (off)")
            .accessibilityIdentifier("PinnedPreview.KeepOnTop")
            .accessibilityValue(keepsOnTop ? "on" : "off")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: ScopySize.Icon.xs))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ScopyColors.mutedText)
            .help("Unpin preview")
            .accessibilityIdentifier("PinnedPreview.Close")
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.vertical, ScopySpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The header doubles as the drag handle; `isMovableByWindowBackground` moves the window
        // from any non-interactive area, and the title bar itself is transparent.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var previewContent: some View {
        switch preview.kind {
        case .image:
            HistoryItemImagePreviewView(
                model: preview.model,
                thumbnailPath: preview.item.thumbnailPath
            )
        case .text:
            HistoryItemTextPreviewView(
                model: preview.model,
                markdownWebViewController: markdownWebViewController
            )
        case .file:
            HistoryItemFilePreviewView(
                model: preview.model,
                thumbnailPath: preview.item.thumbnailPath,
                kind: preview.filePreviewKind ?? .other,
                filePath: preview.filePreviewPath,
                markdownWebViewController: markdownWebViewController
            )
        }
    }

    private var title: String {
        let trimmed = preview.item.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Preview" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(80))
    }
}
