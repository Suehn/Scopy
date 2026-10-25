import AppKit
import ScopyKit
import SwiftUI

/// What a pinned preview shows.
///
/// The content is a snapshot the hover preview already rendered, held by the controller rather
/// than by the row. That is what makes a pinned preview survive scrolling, row recycling and
/// hovering other rows: the row's interaction session may be released at any time, and none of
/// it is on this path.
@MainActor
struct PinnedPreview {
    let revision: ClipboardItemContentRevision
    let kind: HoverPreviewPopoverKind
    let item: ClipboardItemDTO
    let filePreviewKind: FilePreviewKind?
    let filePreviewPath: String?
    let model: HoverPreviewModel
    let markdownWebViewController: MarkdownPreviewWebViewController?

    /// Capture before dismissing the row. This value owns both the content snapshot and its
    /// transferred WebView across the gap between closing the popover and opening the window.
    init?(
        item: ClipboardItemDTO,
        revision: ClipboardItemContentRevision,
        kind: HoverPreviewPopoverKind,
        filePreviewKind: FilePreviewKind?,
        filePreviewPath: String?,
        source: HoverPreviewModel,
        markdownWebViewController: MarkdownPreviewWebViewController?
    ) {
        guard source.hasRenderedContent else { return nil }
        self.revision = revision
        self.kind = kind
        self.item = item
        self.filePreviewKind = filePreviewKind
        self.filePreviewPath = filePreviewPath
        model = HoverPreviewModel()
        model.adoptRenderedContent(from: source)
        self.markdownWebViewController = markdownWebViewController
    }

    var itemID: UUID { item.id }

    /// Size the window should open at: what the popover was already showing.
    ///
    /// The hover preview has measured its content by this point (the WebView reported the
    /// Markdown layout, the image knows its pixel size), so the first frame matches what the user
    /// was looking at instead of snapping to the window's minimum.
    func preferredContentSize() -> CGSize {
        let maxWidth = HoverPreviewScreenMetrics.maxPopoverWidthPoints()
        let maxHeight = HoverPreviewScreenMetrics.maxPopoverHeightPoints()

        if let size = model.presentationSize { return size }

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
            height: min(maxHeight, max(200, contentSize.height))
        )
    }
}

/// Owns each snapshot, transferred WebView and panel from admission until close, including the
/// turn before its SwiftUI host is mounted. The list creates a fresh controller for later hovers.
@MainActor
final class PinnedPreviewController {
    private final class Window {
        let preview: PinnedPreview
        let panel: PinnedPreviewPanel

        init(preview: PinnedPreview, panel: PinnedPreviewPanel) {
            self.preview = preview
            self.panel = panel
        }
    }

    private var windows: [UUID: Window] = [:]
    private var lastAppliedClearGeneration: UInt64 = 0
    private var lastAppliedStamp: UInt64 = 0

    func isPinned(itemID: UUID) -> Bool { windows[itemID] != nil }

    func focus(itemID: UUID) {
        guard let panel = windows[itemID]?.panel, panel.contentView != nil else { return }
        panel.orderFrontRegardless()
    }

    @discardableResult
    func pin(
        _ preview: PinnedPreview,
        settingsViewModel: SettingsViewModel,
        onPresented: @escaping @MainActor () -> Void = { }
    ) -> Bool {
        let itemID = preview.itemID
        guard windows[itemID] == nil else { return false }
        let window = Window(preview: preview, panel: makePanel())
        window.panel.onCloseRequested = { [weak self, weak window] in
            if let window { self?.dismiss(window) }
        }
        windows[itemID] = window
        // Register before yielding so deletion and replacement also invalidate a pending pin.
        // Hosting waits one turn for SwiftUI to dismantle the previous popover surface.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windows[itemID] === window else { return }
            self.present(window, settingsViewModel: settingsViewModel)
            onPresented()
        }
        return true
    }

    private func present(_ window: Window, settingsViewModel: SettingsViewModel) {
        let preview = window.preview
        let panel = window.panel
        panel.contentView = NSHostingView(
            rootView: PinnedPreviewWindowView(
                preview: preview,
                initialKeepsOnTop: Self.storedKeepsOnTop,
                onKeepsOnTopChange: { [weak panel] value in
                    UserDefaults.standard.set(value, forKey: Self.keepsOnTopDefaultsKey)
                    if let panel { Self.applyKeepsOnTop(value, to: panel) }
                },
                onDismiss: { [weak self, weak window] in
                    if let window { self?.dismiss(window) }
                }
            ).environment(settingsViewModel)
        )
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.setContentSize(preview.preferredContentSize())
            panel.center()
        }
        if let previous = windows.values.first(where: { $0 !== window && $0.panel.contentView != nil })?.panel {
            panel.setFrameOrigin(NSPoint(x: previous.frame.minX + 28, y: previous.frame.minY - 28))
        }
        let visibleFrame = panel.screen?.visibleFrame ?? HoverPreviewScreenMetrics.activeVisibleFrame()
        panel.setFrame(Self.fittedFrame(panel.frame, in: visibleFrame), display: false)
        panel.orderFrontRegardless()
    }

    func dismiss(itemID: UUID) {
        guard let window = windows.removeValue(forKey: itemID) else { return }
        window.preview.model.cancelExportTasks()
        window.preview.markdownWebViewController?.detachWebView()
        let panel = window.panel
        if panel.contentView != nil { panel.saveFrame(usingName: Self.frameAutosaveName) }
        if panel.onCloseRequested != nil {
            panel.onCloseRequested = nil
            panel.close()
        }
        panel.contentView = nil
    }

    private func dismiss(_ window: Window) {
        guard windows[window.preview.itemID] === window else { return }
        dismiss(itemID: window.preview.itemID)
    }

    func dismiss() {
        for itemID in Array(windows.keys) { dismiss(itemID: itemID) }
    }

    func reconcile(snapshot: HistoryContentRevisionReconciliationSnapshot) {
        let clearChanged = lastAppliedClearGeneration != snapshot.clearGeneration
        let previousStamp = lastAppliedStamp
        lastAppliedClearGeneration = snapshot.clearGeneration
        lastAppliedStamp = snapshot.stamp
        for window in Array(windows.values) {
            let preview = window.preview
            if snapshot.invalidates(
                itemID: preview.itemID,
                currentRevision: preview.revision,
                clearGenerationChanged: clearChanged,
                lastAppliedStamp: previousStamp
            ) {
                dismiss(itemID: preview.itemID)
            }
        }
    }

    /// Saved frames may refer to a disconnected or smaller screen.
    static func fittedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let width = min(max(320, frame.width), visibleFrame.width)
        let height = min(max(200, frame.height), visibleFrame.height)
        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width, height: height
        )
    }

    private func makePanel() -> PinnedPreviewPanel {
        let panel = PinnedPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentView = nil
        panel.title = String(localized: "Preview")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        Self.applyKeepsOnTop(Self.storedKeepsOnTop, to: panel)
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: 320, height: 200)
        return panel
    }

    private static func applyKeepsOnTop(_ value: Bool, to panel: NSPanel) {
        panel.isFloatingPanel = value
        panel.level = value ? .floating : .normal
    }

    private static let frameAutosaveName = "ScopyPinnedPreviewPanel"
    private static let keepsOnTopDefaultsKey = "ScopyPinnedPreviewKeepsOnTop"
    private static var storedKeepsOnTop: Bool {
        UserDefaults.standard.object(forKey: keepsOnTopDefaultsKey) as? Bool ?? true
    }

    #if DEBUG
    var previewsForTesting: [UUID: PinnedPreview] { windows.mapValues(\.preview) }
    #endif
}

/// A nonactivating, resizable reading window; each window has its own content owner.
final class PinnedPreviewPanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    override var canBecomeMain: Bool { false }
    override func close() {
        let onCloseRequested = onCloseRequested
        self.onCloseRequested = nil
        super.close()
        onCloseRequested?()
    }
}
