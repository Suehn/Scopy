import AppKit
import Observation
import ScopyKit
import SwiftUI

/// What a pinned preview shows.
///
/// The content is a snapshot the hover preview already rendered, held by the controller rather
/// than by the row. That is what makes a pinned preview survive scrolling, row recycling and
/// hovering other rows: the row's interaction session may be released at any time, and none of
/// it is on this path.
@MainActor
struct PinnedPreview: Identifiable {
    let itemID: UUID
    let revision: ClipboardItemContentRevision
    let kind: HoverPreviewPopoverKind
    let item: ClipboardItemDTO
    let filePreviewKind: FilePreviewKind?
    let filePreviewPath: String?
    let model: HoverPreviewModel

    nonisolated var id: UUID { itemID }

    /// Size the window should open at: what the popover was already showing.
    ///
    /// The hover preview has measured its content by this point (the WebView reported the
    /// Markdown layout, the image knows its pixel size), so the first frame matches what the user
    /// was looking at instead of snapping to the window's minimum.
    func preferredContentSize(chromeHeight: CGFloat) -> CGSize {
        let maxWidth = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
        let maxHeight = HoverPreviewScreenMetrics.maxPopoverHeightPoints()

        let contentSize: CGSize
        if model.isMarkdown, let measured = model.markdownContentSize {
            contentSize = CGSize(width: maxWidth, height: measured.height)
        } else if let image = model.previewCGImage, image.width > 0, image.height > 0 {
            let aspect = CGFloat(image.height) / CGFloat(image.width)
            contentSize = CGSize(width: maxWidth, height: maxWidth * aspect)
        } else {
            contentSize = CGSize(width: maxWidth, height: maxHeight * 0.6)
        }

        return CGSize(
            width: min(maxWidth, max(320, contentSize.width)),
            height: min(maxHeight, max(200, contentSize.height + chromeHeight))
        )
    }
}

/// Owns the single pinned preview window.
///
/// One at a time: the Markdown preview is one shared `WKWebView`, and a second host would take it
/// away from the first. For the same reason the list stops presenting hover previews while a
/// preview is pinned.
@Observable
@MainActor
final class PinnedPreviewController {
    private(set) var pinned: PinnedPreview?

    @ObservationIgnored private var panel: PinnedPreviewPanel?
    @ObservationIgnored private var lastAppliedClearGeneration: UInt64 = 0
    @ObservationIgnored private var lastAppliedDeletionEvictionGeneration: UInt64 = 0

    var isPinned: Bool { pinned != nil }

    /// Whether the window floats above other apps. On by default: a pinned preview exists to be
    /// read while working somewhere else. Turning it off drops it to an ordinary window level.
    var keepsOnTop: Bool = PinnedPreviewController.storedKeepsOnTop {
        didSet {
            guard keepsOnTop != oldValue else { return }
            UserDefaults.standard.set(keepsOnTop, forKey: Self.keepsOnTopDefaultsKey)
            if let panel { Self.applyKeepsOnTop(keepsOnTop, to: panel) }
        }
    }

    func isPinned(itemID: UUID) -> Bool {
        pinned?.itemID == itemID
    }

    /// Pins the preview a row is currently showing.
    ///
    /// `source` is the row's live preview model; its rendered payload is copied so the row stays
    /// free to reset or release its own session immediately afterwards.
    func pin(
        item: ClipboardItemDTO,
        revision: ClipboardItemContentRevision,
        kind: HoverPreviewPopoverKind,
        filePreviewKind: FilePreviewKind?,
        filePreviewPath: String?,
        source: HoverPreviewModel,
        settingsViewModel: SettingsViewModel,
        markdownWebViewController: MarkdownPreviewWebViewController
    ) {
        guard source.hasRenderedContent else { return }

        let model = HoverPreviewModel()
        model.adoptRenderedContent(from: source)

        pinned = PinnedPreview(
            itemID: item.id,
            revision: revision,
            kind: kind,
            item: item,
            filePreviewKind: filePreviewKind,
            filePreviewPath: filePreviewPath,
            model: model
        )

        present(
            settingsViewModel: settingsViewModel,
            markdownWebViewController: markdownWebViewController
        )
    }

    func dismiss() {
        guard pinned != nil else { return }
        pinned = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Closes a pinned preview whose item no longer exists, or whose payload was replaced. The
    /// window shows a snapshot, so a superseded revision must not stay on screen.
    func reconcile(snapshot: HistoryContentRevisionReconciliationSnapshot) {
        let clearGenerationChanged = lastAppliedClearGeneration != snapshot.clearGeneration
        let deletionEvictionGenerationChanged =
            lastAppliedDeletionEvictionGeneration != snapshot.deletionEvictionGeneration
        lastAppliedClearGeneration = snapshot.clearGeneration
        lastAppliedDeletionEvictionGeneration = snapshot.deletionEvictionGeneration

        guard let pinned else { return }
        if snapshot.invalidates(
            itemID: pinned.itemID,
            currentRevision: pinned.revision,
            clearGenerationChanged: clearGenerationChanged,
            deletionEvictionGenerationChanged: deletionEvictionGenerationChanged
        ) {
            dismiss()
        }
    }

    // MARK: - Window

    private func present(
        settingsViewModel: SettingsViewModel,
        markdownWebViewController: MarkdownPreviewWebViewController
    ) {
        guard let pinned else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hostView = NSHostingView(
            rootView: PinnedPreviewWindowView(
                preview: pinned,
                markdownWebViewController: markdownWebViewController,
                initialKeepsOnTop: keepsOnTop,
                onKeepsOnTopChange: { [weak self] value in self?.keepsOnTop = value },
                onDismiss: { [weak self] in self?.dismiss() }
            )
            .environment(settingsViewModel)
        )
        panel.contentView = hostView

        // AppKit restores a saved frame from the autosave name; only a first-ever pin needs a
        // size, and it takes it from what the popover was already showing.
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.setContentSize(
                pinned.preferredContentSize(chromeHeight: PinnedPreviewWindowView.chromeHeight)
            )
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> PinnedPreviewPanel {
        let panel = PinnedPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pinned Preview"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        Self.applyKeepsOnTop(keepsOnTop, to: panel)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        panel.minSize = NSSize(width: 320, height: 200)
        panel.onCloseRequested = { [weak self] in self?.dismiss() }
        return panel
    }

    /// `isFloatingPanel` is what makes AppKit treat the window as a palette; the level is what
    /// actually orders it above other apps. Both have to follow the toggle.
    private static func applyKeepsOnTop(_ keepsOnTop: Bool, to panel: NSPanel) {
        panel.isFloatingPanel = keepsOnTop
        panel.level = keepsOnTop ? .floating : .normal
    }

    private static let frameAutosaveName = "ScopyPinnedPreviewPanel"
    private static let keepsOnTopDefaultsKey = "ScopyPinnedPreviewKeepsOnTop"

    private static var storedKeepsOnTop: Bool {
        UserDefaults.standard.object(forKey: keepsOnTopDefaultsKey) as? Bool ?? true
    }
}

/// The pinned preview window.
///
/// It takes key focus like any palette window so its close button, scrolling and text selection
/// behave normally; `FloatingPanelDismissPolicy` is what keeps the history panel from closing
/// underneath it. `.nonactivatingPanel` means clicking it does not pull Scopy to the front when
/// the user is working in another app.
final class PinnedPreviewPanel: NSPanel {
    var onCloseRequested: (() -> Void)?

    override var canBecomeMain: Bool { false }

    override func close() {
        // The frame is autosaved on every move and resize; closing only has to tell the owner.
        super.close()
        onCloseRequested?()
    }
}
