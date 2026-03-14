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
        private weak var cachedWindow: NSWindow?
        private weak var cachedWindowResolvedScrollView: NSScrollView?
        private var localEventMonitor: Any?
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
                cachedWindow = nil
                cachedWindowResolvedScrollView = nil
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
            installEventMonitorIfNeeded()

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
            cachedWindow = nil
            cachedWindowResolvedScrollView = nil
            removeEventMonitor()
            if HistoryListScrollState.shared.isPointerInteractionActive {
                HistoryListScrollState.shared.endPointerInteraction()
                NotificationCenter.default.post(name: .historyListInteractionDidEnd, object: nil)
            }
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

        private func installEventMonitorIfNeeded() {
            guard localEventMonitor == nil else { return }
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handlePointerInteractionEvent(event)
                return event
            }
        }

        private func removeEventMonitor() {
            if let localEventMonitor {
                NSEvent.removeMonitor(localEventMonitor)
                self.localEventMonitor = nil
            }
        }

        private func handlePointerInteractionEvent(_ event: NSEvent) {
            guard let scrollView = observedScrollView,
                  let window = scrollView.window,
                  event.window === window else { return }

            let pointInScrollView = scrollView.convert(event.locationInWindow, from: nil)
            let isInsideScrollView = scrollView.bounds.contains(pointInScrollView)

            switch event.type {
            case .leftMouseDown:
                guard isInsideScrollView else { return }
                guard !HistoryListScrollState.shared.isPointerInteractionActive else { return }
                HistoryListScrollState.shared.beginPointerInteraction()
                NotificationCenter.default.post(name: .historyListInteractionDidStart, object: nil)
            case .leftMouseUp:
                guard HistoryListScrollState.shared.isPointerInteractionActive else { return }
                HistoryListScrollState.shared.endPointerInteraction()
                NotificationCenter.default.post(name: .historyListInteractionDidEnd, object: nil)
            default:
                break
            }
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
            guard let window else { return nil }
            if PerfFeatureFlags.scrollResolverCacheEnabled,
               cachedWindow === window,
               let cachedWindowResolvedScrollView {
                return cachedWindowResolvedScrollView
            }

            guard let contentView = window.contentView else { return nil }
            let resolved = findFirstScrollView(in: contentView)
            if PerfFeatureFlags.scrollResolverCacheEnabled {
                cachedWindow = window
                cachedWindowResolvedScrollView = resolved
            }
            return resolved
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
