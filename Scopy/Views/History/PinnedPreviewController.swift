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

/// Owns independent snapshots and WebViews. The list lends its current WebView only when
/// creating a window, then allocates a fresh hover controller for subsequent previews.
@Observable
@MainActor
final class PinnedPreviewController {
    private(set) var previews: [UUID: PinnedPreview] = [:]
    @ObservationIgnored private var panels: [UUID: PinnedPreviewPanel] = [:]
    @ObservationIgnored private var lastAppliedClearGeneration: UInt64 = 0
    @ObservationIgnored private var lastAppliedDeletionEvictionGeneration: UInt64 = 0

    var isPinned: Bool { !previews.isEmpty }

    func isPinned(itemID: UUID) -> Bool { previews[itemID] != nil }

    func focus(itemID: UUID) {
        panels[itemID]?.orderFrontRegardless()
    }

    /// Snapshots synchronously, before dismissing the row can clear its interaction model.
    @discardableResult
    func pin(
        item: ClipboardItemDTO,
        revision: ClipboardItemContentRevision,
        kind: HoverPreviewPopoverKind,
        filePreviewKind: FilePreviewKind?,
        filePreviewPath: String?,
        source: HoverPreviewModel,
        settingsViewModel: SettingsViewModel,
        markdownWebViewController: MarkdownPreviewWebViewController?
    ) -> Bool {
        guard source.hasRenderedContent, previews[item.id] == nil else { return false }
        let model = HoverPreviewModel()
        model.adoptRenderedContent(from: source)
        let preview = PinnedPreview(
            itemID: item.id, revision: revision, kind: kind, item: item,
            filePreviewKind: filePreviewKind, filePreviewPath: filePreviewPath, model: model
        )
        previews[item.id] = preview
        let panel = makePanel(itemID: item.id)
        panels[item.id] = panel
        panel.contentView = NSHostingView(
            rootView: PinnedPreviewWindowView(
                preview: preview,
                markdownWebViewController: markdownWebViewController,
                initialKeepsOnTop: Self.storedKeepsOnTop,
                onKeepsOnTopChange: { [weak panel] value in
                    UserDefaults.standard.set(value, forKey: Self.keepsOnTopDefaultsKey)
                    if let panel { Self.applyKeepsOnTop(value, to: panel) }
                },
                onDismiss: { [weak self] in self?.dismiss(itemID: item.id) }
            ).environment(settingsViewModel)
        )
        if !panel.setFrameUsingName(Self.frameAutosaveName + "." + item.id.uuidString),
           !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.setContentSize(preview.preferredContentSize())
            panel.center()
        }
        if let previous = panels.values.first(where: { $0 !== panel }) {
            panel.setFrameOrigin(NSPoint(x: previous.frame.minX + 28, y: previous.frame.minY - 28))
        }
        let visibleFrame = panel.screen?.visibleFrame ?? HoverPreviewScreenMetrics.activeVisibleFrame()
        panel.setFrame(Self.fittedFrame(panel.frame, in: visibleFrame), display: false)
        panel.orderFrontRegardless()
        return true
    }

    func dismiss(itemID: UUID) {
        previews.removeValue(forKey: itemID)?.model.cancelExportTasks()
        guard let panel = panels.removeValue(forKey: itemID) else { return }
        panel.saveFrame(usingName: Self.frameAutosaveName)
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func dismiss() {
        for itemID in Array(previews.keys) { dismiss(itemID: itemID) }
    }

    func reconcile(snapshot: HistoryContentRevisionReconciliationSnapshot) {
        let clearChanged = lastAppliedClearGeneration != snapshot.clearGeneration
        let evictionChanged = lastAppliedDeletionEvictionGeneration != snapshot.deletionEvictionGeneration
        lastAppliedClearGeneration = snapshot.clearGeneration
        lastAppliedDeletionEvictionGeneration = snapshot.deletionEvictionGeneration
        for preview in Array(previews.values) where snapshot.invalidates(
            itemID: preview.itemID,
            currentRevision: preview.revision,
            clearGenerationChanged: clearChanged,
            deletionEvictionGenerationChanged: evictionChanged
        ) {
            dismiss(itemID: preview.itemID)
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

    private func makePanel(itemID: UUID) -> PinnedPreviewPanel {
        let panel = PinnedPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Preview"
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
        panel.setFrameAutosaveName(Self.frameAutosaveName + "." + itemID.uuidString)
        panel.minSize = NSSize(width: 320, height: 200)
        panel.onCloseRequested = { [weak self] in self?.dismiss(itemID: itemID) }
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
}

/// A nonactivating, resizable reading window; each window has its own content owner.
final class PinnedPreviewPanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    override var canBecomeMain: Bool { false }
    override func close() {
        super.close()
        onCloseRequested?()
    }
}
