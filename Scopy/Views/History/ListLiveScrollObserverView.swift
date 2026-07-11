import AppKit
import SwiftUI

struct ListLiveScrollObserverView: NSViewRepresentable {
    let interactionCoordinator: HistoryListInteractionCoordinator
    let onScrollStart: () -> Void
    let onScrollEnd: () -> Void
    var onScrollViewAttach: ((NSScrollView) -> Void)? = nil

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.interactionCoordinator = interactionCoordinator
        view.onScrollStart = onScrollStart
        view.onScrollEnd = onScrollEnd
        view.onScrollViewAttach = onScrollViewAttach
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.interactionCoordinator = interactionCoordinator
        nsView.onScrollStart = onScrollStart
        nsView.onScrollEnd = onScrollEnd
        nsView.onScrollViewAttach = onScrollViewAttach
        nsView.attachIfNeeded()
    }
}

extension ListLiveScrollObserverView {
    final class ObserverView: NSView {
        enum ScrollbarAxis: Equatable {
            case vertical
            case horizontal
        }

        private struct PointerInteractionOwnership {
            let monitorGeneration: UUID
            let coordinator: HistoryListInteractionCoordinator
            let token: HistoryListInteractionCoordinator.PointerInteractionToken
        }

        var interactionCoordinator: HistoryListInteractionCoordinator?
        var onScrollStart: (() -> Void)?
        var onScrollEnd: (() -> Void)?
        var onScrollViewAttach: ((NSScrollView) -> Void)?
        var pressedMouseButtonsProvider: () -> Int = {
            NSEvent.pressedMouseButtons
        }

        private weak var observedScrollView: NSScrollView?
        private weak var attachedWindow: NSWindow?
        private weak var cachedWindow: NSWindow?
        private weak var cachedWindowResolvedScrollView: NSScrollView?
        private var localEventMonitor: Any?
        private var eventMonitorGeneration: UUID?
        private var pointerInteractionOwnership: PointerInteractionOwnership?
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

        override func layout() {
            super.layout()
            // SwiftUI can mount the representable one layout pass before List's NSTableView.
            // Re-resolve on the natural AppKit layout boundary; once the list is found the cache
            // below makes this O(1).
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard let scrollView = findEnclosingScrollView()
                ?? findScrollViewInWindow(allowGenericFallback: onScrollViewAttach != nil)
            else { return }
            guard observedScrollView !== scrollView || attachedWindow !== scrollView.window else {
                return
            }

            detach()
            observedScrollView = scrollView
            attachedWindow = scrollView.window
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
            attachedWindow = nil
            cachedWindow = nil
            cachedWindowResolvedScrollView = nil
            removeEventMonitor()
            endOwnedPointerInteraction()
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
            // Perform the fallback even if AppKit omitted the matching start notification.
            // A consumed mouse-up leaves the physical button clear. If it is still down, keep the
            // independent pointer reason active until the paired up/detach path ends its token.
            if (pressedMouseButtonsProvider() & 1) == 0 {
                endOwnedPointerInteraction()
            }
            guard isLiveScrolling else { return }
            isLiveScrolling = false
            onScrollEnd?()
        }

        private func installEventMonitorIfNeeded() {
            guard localEventMonitor == nil else { return }
            let generation = UUID()
            eventMonitorGeneration = generation
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handlePointerInteractionEvent(event, monitorGeneration: generation)
                return event
            }
        }

        private func removeEventMonitor() {
            if let localEventMonitor {
                NSEvent.removeMonitor(localEventMonitor)
                self.localEventMonitor = nil
            }
            eventMonitorGeneration = nil
        }

        private func handlePointerInteractionEvent(
            _ event: NSEvent,
            monitorGeneration: UUID
        ) {
            handlePointerInteraction(
                type: event.type,
                eventWindow: event.window,
                locationInWindow: event.locationInWindow,
                monitorGeneration: monitorGeneration
            )
        }

        /// Test seam for the monitor reducer. Production calls use the generation captured by the
        /// installed event monitor, so a queued callback from an old attachment cannot end a newer
        /// scroll-view session.
        func handlePointerInteraction(
            type: NSEvent.EventType,
            eventWindow: NSWindow?,
            locationInWindow: NSPoint
        ) {
            guard let eventMonitorGeneration else { return }
            handlePointerInteraction(
                type: type,
                eventWindow: eventWindow,
                locationInWindow: locationInWindow,
                monitorGeneration: eventMonitorGeneration
            )
        }

        private func handlePointerInteraction(
            type: NSEvent.EventType,
            eventWindow: NSWindow?,
            locationInWindow: NSPoint,
            monitorGeneration: UUID
        ) {
            guard eventMonitorGeneration == self.eventMonitorGeneration else { return }

            switch type {
            case .leftMouseDown:
                // A new down always retires this observer's previous paired ownership first. If
                // this down is ordinary content, the state remains idle and the event passes on.
                endOwnedPointerInteraction()
                guard let scrollView = observedScrollView,
                      let eventWindow,
                      Self.scrollbarAxis(
                        in: scrollView,
                        eventWindow: eventWindow,
                        locationInWindow: locationInWindow
                      ) != nil,
                      let interactionCoordinator
                else { return }

                let token = interactionCoordinator.beginPointerInteraction()
                pointerInteractionOwnership = PointerInteractionOwnership(
                    monitorGeneration: monitorGeneration,
                    coordinator: interactionCoordinator,
                    token: token
                )
                reconcileConsumedMouseUp(
                    monitorGeneration: monitorGeneration,
                    pointerToken: token
                )
            case .leftMouseUp:
                guard pointerInteractionOwnership?.monitorGeneration == monitorGeneration else {
                    return
                }
                endOwnedPointerInteraction()
            default:
                break
            }
        }

        private func endOwnedPointerInteraction() {
            guard let pointerInteractionOwnership else { return }
            self.pointerInteractionOwnership = nil
            pointerInteractionOwnership.coordinator.endPointerInteraction(
                token: pointerInteractionOwnership.token
            )
        }

        private func endOwnedPointerInteraction(
            monitorGeneration: UUID,
            pointerToken: HistoryListInteractionCoordinator.PointerInteractionToken
        ) {
            guard pointerInteractionOwnership?.monitorGeneration == monitorGeneration,
                  pointerInteractionOwnership?.token == pointerToken else {
                return
            }
            endOwnedPointerInteraction()
        }

        private func reconcileConsumedMouseUp(
            monitorGeneration: UUID,
            pointerToken: HistoryListInteractionCoordinator.PointerInteractionToken
        ) {
            Task { @MainActor [weak self] in
                // Let the mouse-down finish normal AppKit dispatch/tracking first. Some controls
                // consume the paired mouse-up inside their nested tracking loop.
                await Task.yield()
                guard let self, (self.pressedMouseButtonsProvider() & 1) == 0 else { return }
                self.endOwnedPointerInteraction(
                    monitorGeneration: monitorGeneration,
                    pointerToken: pointerToken
                )
            }
        }

        static func scrollbarAxis(
            in scrollView: NSScrollView,
            eventWindow: NSWindow,
            locationInWindow: NSPoint
        ) -> ScrollbarAxis? {
            guard scrollView.window === eventWindow,
                  let contentView = eventWindow.contentView
            else { return nil }

            // `NSView.hitTest(_:)` expects a point in the receiver's *superview* coordinate
            // system. A SwiftUI hosting content view is flipped, so converting into the content
            // view's own coordinates mirrors asymmetric hits such as the horizontal scroller.
            guard let hitView = contentView.hitTest(locationInWindow) else { return nil }

            return scrollbarAxis(
                in: scrollView,
                eventWindow: eventWindow,
                locationInWindow: locationInWindow,
                hitView: hitView,
                testPart: { scroller, point in
                    scroller.testPart(point)
                }
            )
        }

        /// Deterministic AppKit seam for testing visibility, identity, and `testPart` routing
        /// without synthesizing global mouse events.
        static func scrollbarAxis(
            in scrollView: NSScrollView,
            eventWindow: NSWindow,
            locationInWindow: NSPoint,
            hitView: NSView,
            testPart: (NSScroller, NSPoint) -> NSScroller.Part
        ) -> ScrollbarAxis? {
            guard scrollView.window === eventWindow else { return nil }

            let candidates: [(NSScroller?, ScrollbarAxis, Bool)] = [
                (scrollView.verticalScroller, .vertical, scrollView.hasVerticalScroller),
                (scrollView.horizontalScroller, .horizontal, scrollView.hasHorizontalScroller)
            ]

            for (scroller, axis, isInstalled) in candidates {
                guard isInstalled,
                      let scroller,
                      isVisiblyHittable(scroller, in: eventWindow),
                      hitView === scroller || hitView.isDescendant(of: scroller),
                      testPart(scroller, locationInWindow) != .noPart
                else { continue }
                return axis
            }

            return nil
        }

        private static func isVisiblyHittable(
            _ scroller: NSScroller,
            in window: NSWindow
        ) -> Bool {
            guard scroller.window === window,
                  scroller.isEnabled,
                  !scroller.isHiddenOrHasHiddenAncestor,
                  !scroller.bounds.isEmpty else {
                return false
            }

            var ancestor: NSView? = scroller
            while let view = ancestor {
                guard view.alphaValue > 0 else { return false }
                ancestor = view.superview
            }
            return true
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

        private func findScrollViewInWindow(allowGenericFallback: Bool) -> NSScrollView? {
            guard let window, let contentView = window.contentView else { return nil }
            if PerfFeatureFlags.scrollResolverCacheEnabled,
               cachedWindow === window,
               let cachedWindowResolvedScrollView,
               cachedWindowResolvedScrollView.window === window,
               cachedWindowResolvedScrollView.isDescendant(of: contentView),
               Self.isListScrollView(cachedWindowResolvedScrollView) {
                return cachedWindowResolvedScrollView
            }

            let resolved = findFirstListScrollView(in: contentView)
                ?? (allowGenericFallback ? findFirstGenericScrollView(in: contentView) : nil)
            if PerfFeatureFlags.scrollResolverCacheEnabled,
               let resolved,
               Self.isListScrollView(resolved) {
                cachedWindow = window
                cachedWindowResolvedScrollView = resolved
            } else {
                cachedWindow = nil
                cachedWindowResolvedScrollView = nil
            }
            return resolved
        }

        private static func isListScrollView(_ scrollView: NSScrollView) -> Bool {
            scrollView.documentView is NSTableView || scrollView.documentView is NSOutlineView
        }

        private func findFirstListScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                if Self.isListScrollView(scrollView) {
                    return scrollView
                }
            }
            for subview in view.subviews {
                if let found = findFirstListScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }

        private func findFirstGenericScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView != nil {
                return scrollView
            }
            for subview in view.subviews {
                if let found = findFirstGenericScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}
