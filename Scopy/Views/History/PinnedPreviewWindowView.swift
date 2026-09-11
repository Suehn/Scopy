import AppKit
import ScopyKit
import SwiftUI

/// Contents of the pinned preview window.
///
/// The same preview views the hover popover uses, laid out against the window's live content size
/// instead of the screen-derived popover budget, while preserving the document's canonical
/// layout and display-fit scale.
struct PinnedPreviewWindowView: View {
    let preview: PinnedPreview
    let markdownWebViewController: MarkdownPreviewWebViewController?
    let onKeepsOnTopChange: (Bool) -> Void
    let onDismiss: () -> Void

    /// Owned here so the floating controls re-render on toggle; the controller applies the window level.
    @State private var keepsOnTop: Bool

    init(
        preview: PinnedPreview,
        markdownWebViewController: MarkdownPreviewWebViewController?,
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
        GeometryReader { proxy in
            previewContent
                .environment(\.hoverPreviewSizeBudget, .window(proxy.size))
                .environment(\.previewWindowActions, PreviewWindowActions(
                    close: onDismiss,
                    toggleFloating: {
                        keepsOnTop.toggle()
                        onKeepsOnTopChange(keepsOnTop)
                    },
                    keepsOnTop: keepsOnTop
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .frame(minWidth: 320, minHeight: 200)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PinnedPreview.Window")
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

}
