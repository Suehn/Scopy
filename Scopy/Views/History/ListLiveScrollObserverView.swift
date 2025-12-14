import AppKit
import SwiftUI

struct ListLiveScrollObserverView: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScroll = onScroll
        nsView.attachIfNeeded()
    }
}

extension ListLiveScrollObserverView {
    final class ObserverView: NSView {
        var onScroll: (() -> Void)?

        private weak var observedScrollView: NSScrollView?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil {
                detach()
            } else {
                attachIfNeeded()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                attachIfNeeded()
            }
        }

        func attachIfNeeded() {
            guard let scrollView = findEnclosingScrollView() else { return }
            guard observedScrollView !== scrollView else { return }

            detach()
            observedScrollView = scrollView

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleLiveScroll(_:)),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleLiveScroll(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        private func detach() {
            if let observedScrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSScrollView.didLiveScrollNotification,
                    object: observedScrollView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSScrollView.didEndLiveScrollNotification,
                    object: observedScrollView
                )
            }
            observedScrollView = nil
        }

        @objc private func handleLiveScroll(_ notification: Notification) {
            onScroll?()
        }

        private func findEnclosingScrollView() -> NSScrollView? {
            if let scrollView = enclosingScrollView {
                return scrollView
            }

            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}
