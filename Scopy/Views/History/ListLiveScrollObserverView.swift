import AppKit
import SwiftUI

struct ListLiveScrollObserverView: NSViewRepresentable {
    let onScrollStart: () -> Void
    let onScrollEnd: () -> Void
    var onScrollViewAttach: ((NSScrollView) -> Void)? = nil

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScrollStart = onScrollStart
        view.onScrollEnd = onScrollEnd
        view.onScrollViewAttach = onScrollViewAttach
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScrollStart = onScrollStart
        nsView.onScrollEnd = onScrollEnd
        nsView.onScrollViewAttach = onScrollViewAttach
        nsView.attachIfNeeded()
    }
}

extension ListLiveScrollObserverView {
    final class ObserverView: NSView {
        var onScrollStart: (() -> Void)?
        var onScrollEnd: (() -> Void)?
        var onScrollViewAttach: ((NSScrollView) -> Void)?

        private weak var observedScrollView: NSScrollView?
        private var isLiveScrolling = false

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
            guard let scrollView = findEnclosingScrollView() ?? findScrollViewInWindow() else { return }
            guard observedScrollView !== scrollView else { return }

            detach()
            observedScrollView = scrollView
            onScrollViewAttach?(scrollView)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollStart(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollEnd(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        private func detach() {
            if let observedScrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSScrollView.willStartLiveScrollNotification,
                    object: observedScrollView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSScrollView.didEndLiveScrollNotification,
                    object: observedScrollView
                )
            }
            observedScrollView = nil
            if isLiveScrolling {
                isLiveScrolling = false
                onScrollEnd?()
            }
        }

        @objc private func handleScrollStart(_ notification: Notification) {
            guard !isLiveScrolling else { return }
            isLiveScrolling = true
            onScrollStart?()
        }

        @objc private func handleScrollEnd(_ notification: Notification) {
            guard isLiveScrolling else { return }
            isLiveScrolling = false
            onScrollEnd?()
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

        private func findScrollViewInWindow() -> NSScrollView? {
            guard let contentView = window?.contentView else { return nil }
            return findFirstScrollView(in: contentView)
        }

        private func findFirstScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                if scrollView.documentView is NSTableView || scrollView.documentView is NSOutlineView {
                    return scrollView
                }
            }
            for subview in view.subviews {
                if let found = findFirstScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}
