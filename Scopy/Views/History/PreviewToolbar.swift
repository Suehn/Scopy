import AppKit
import SwiftUI

/// Window actions travel with the host; content-specific controls stay with their preview view.
struct PreviewWindowActions {
    var pin: (@MainActor () -> Void)?
    var close: (@MainActor () -> Void)?
    var toggleFloating: (@MainActor () -> Void)?
    var keepsOnTop = false
    var isPinned: Bool { close != nil }
}

private struct PreviewWindowActionsKey: EnvironmentKey {
    static let defaultValue = PreviewWindowActions()
}

extension EnvironmentValues {
    var previewWindowActions: PreviewWindowActions {
        get { self[PreviewWindowActionsKey.self] }
        set { self[PreviewWindowActionsKey.self] = newValue }
    }
}

struct PreviewToolbar<Controls: View>: View {
    static var height: CGFloat { 34 }
    @Environment(\.previewWindowActions) private var actions
    @State private var isHovered = false
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(spacing: 6) {
            if let pin = actions.pin {
                Button(action: pin) { Image(systemName: "pin") }
                    .help("Keep this preview in a separate window")
                    .accessibilityIdentifier("History.Preview.Pin")
            }
            if let toggle = actions.toggleFloating {
                Button(action: toggle) {
                    Image(systemName: actions.keepsOnTop ? "pin.fill" : "pin")
                }
                .help(actions.keepsOnTop ? "Keep above other apps (on)" : "Keep above other apps (off)")
                .accessibilityIdentifier("PinnedPreview.KeepOnTop")
                .accessibilityValue(actions.keepsOnTop ? "on" : "off")
            }
            Spacer(minLength: 8)
            controls()
                .fixedSize(horizontal: true, vertical: false)
            if let close = actions.close {
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close preview")
                    .accessibilityIdentifier("PinnedPreview.Close")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .opacity(isHovered ? 1 : 0.38)
        .background {
            if actions.isPinned { PreviewWindowDragRegion() }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// Only the toolbar background drags the window; text remains selectable in the document.
private struct PreviewWindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Resize the popover through its public content layout, without changing private AppKit windows.
struct ResizablePreview<Content: View>: View {
    let model: HoverPreviewModel
    let onResizeActivityChange: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    @State private var size: CGSize?
    @State private var measuredSize: CGSize = .zero
    @State private var dragStartSize: CGSize?
    @State private var isGripHovered = false

    var body: some View {
        content()
            .environment(\.hoverPreviewSizeBudget, size.map(HoverPreviewSizeBudget.window) ?? .popover)
            .frame(width: size?.width, height: size?.height, alignment: .top)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { recordSize(proxy.size) }
                        .onChange(of: proxy.size) { _, value in recordSize(value) }
                }
            }
            .onDisappear {
                if dragStartSize != nil {
                    dragStartSize = nil
                    onResizeActivityChange(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .opacity(isGripHovered || dragStartSize != nil ? 0.9 : 0.25)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .onHover { isGripHovered = $0 }
                    .help("Drag to resize preview")
                    .accessibilityIdentifier("History.Preview.Resize")
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartSize == nil {
                                dragStartSize = size ?? measuredSize
                                onResizeActivityChange(true)
                            }
                            guard let initial = dragStartSize else { return }
                            size = CGSize(
                                width: min(max(HoverPreviewScreenMetrics.maxPopoverWidthPoints(), HoverPreviewScreenMetrics.activeVisibleFrame().width * 0.85), max(320, initial.width + value.translation.width)),
                                height: min(HoverPreviewScreenMetrics.maxPopoverHeightPoints(), max(200, initial.height + value.translation.height))
                            )
                        }
                        .onEnded { _ in
                            dragStartSize = nil
                            onResizeActivityChange(false)
                        }
                    )
            }
    }

    private func recordSize(_ value: CGSize) {
        measuredSize = value
        model.presentationSize = value
    }
}
