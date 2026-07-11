import AppKit
import SwiftUI

/// Narrow AppKit bridge for geometry and lifecycle that SwiftUI's popover API does not expose.
struct PopoverWindowObserver: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFrameChange: onFrameChange, onClose: onClose)
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView(frame: .zero)
        view.onWindowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        view.onWindowWillClear = { [weak coordinator = context.coordinator] in
            coordinator?.emitClose()
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        context.coordinator.onFrameChange = onFrameChange
        context.coordinator.onClose = onClose
        nsView.onWindowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        nsView.onWindowWillClear = { [weak coordinator = context.coordinator] in
            coordinator?.emitClose()
        }
        context.coordinator.attach(to: nsView.window)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onFrameChange: (CGRect?) -> Void
        var onClose: () -> Void

        private weak var observedWindow: NSWindow?
        private var hasEmittedClose = false
        private var lastFrame: CGRect?

        init(onFrameChange: @escaping (CGRect?) -> Void, onClose: @escaping () -> Void) {
            self.onFrameChange = onFrameChange
            self.onClose = onClose
            super.init()
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if observedWindow === window {
                emitFrame(window.frame)
                return
            }

            detach()
            observedWindow = window
            hasEmittedClose = false
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleWindowFrameChange(_:)),
                    name: name,
                    object: window
                )
            }
            emitFrame(window.frame)
        }

        func emitClose() {
            guard !hasEmittedClose else { return }
            hasEmittedClose = true
            emitFrame(nil)
            onClose()
            detach()
        }

        @objc private func handleWindowWillClose(_ notification: Notification) {
            emitClose()
        }

        @objc private func handleWindowFrameChange(_ notification: Notification) {
            guard let observedWindow else { return }
            emitFrame(observedWindow.frame)
        }

        private func emitFrame(_ frame: CGRect?) {
            guard lastFrame != frame else { return }
            lastFrame = frame
            onFrameChange(frame)
        }

        private func detach() {
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow)
            }
            observedWindow = nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    final class WindowObservingView: NSView {
        var onWindowDidChange: ((NSWindow?) -> Void)?
        var onWindowWillClear: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowDidChange?(window)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window != nil {
                onWindowWillClear?()
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
