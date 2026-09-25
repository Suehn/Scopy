import AppKit
import ScopyKit
import SwiftUI

/// Marks list scrolls the app performs itself (keyboard selection follow) so that the clip-view
/// bounds signal below does not report them as user scrolling. Trackpad and mouse-wheel scrolling
/// never pass through here.
@MainActor
final class ListProgrammaticScrollGate {
    nonisolated static let defaultDuration: TimeInterval = 0.35

    private let now: () -> CFTimeInterval
    private var ignoreUntil: CFTimeInterval = 0

    init(now: @escaping () -> CFTimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func beginProgrammaticScroll(duration: TimeInterval = ListProgrammaticScrollGate.defaultDuration) {
        ignoreUntil = max(ignoreUntil, now() + duration)
    }

    var isProgrammaticScrollActive: Bool {
        now() < ignoreUntil
    }
}

struct ListLiveScrollObserverView: NSViewRepresentable {
    let interactionCoordinator: HistoryListInteractionCoordinator
    let onScrollStart: () -> Void
    let onScrollEnd: () -> Void
    var onScrollViewAttach: ((NSScrollView) -> Void)? = nil
    var programmaticScrollGate: ListProgrammaticScrollGate? = nil

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.interactionCoordinator = interactionCoordinator
        view.onScrollStart = onScrollStart
        view.onScrollEnd = onScrollEnd
        view.onScrollViewAttach = onScrollViewAttach
        view.programmaticScrollGate = programmaticScrollGate
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.interactionCoordinator = interactionCoordinator
        nsView.onScrollStart = onScrollStart
        nsView.onScrollEnd = onScrollEnd
        nsView.onScrollViewAttach = onScrollViewAttach
        nsView.programmaticScrollGate = programmaticScrollGate
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
        var programmaticScrollGate: ListProgrammaticScrollGate?
        var pressedMouseButtonsProvider: () -> Int = {
            NSEvent.pressedMouseButtons
        }
        /// Scrolling that only shows up as clip-view movement (mouse wheel, momentum tail) ends this
        /// long after the last bounds change.
        var boundsSettleInterval: TimeInterval = 0.12
        /// The clip view also moves for layout (thumbnail heights, initial load) and programmatic
        /// scrolls. Movement starts a scroll only while a scroll-wheel event is current: mouse-wheel
        /// events and their smooth-scroll frames run with that event current, layout does not.
        var isScrollWheelInputCurrent: () -> Bool = {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel else { return false }
            return ProcessInfo.processInfo.systemUptime - event.timestamp < 0.3
        }

        private weak var observedScrollView: NSScrollView?
        private weak var attachedWindow: NSWindow?
        private weak var cachedWindow: NSWindow?
        private weak var cachedWindowResolvedScrollView: NSScrollView?
        private var localEventMonitor: Any?
        private var eventMonitorGeneration: UUID?
        private var pointerInteractionOwnership: PointerInteractionOwnership?
        private var isLiveScrolling = false
        private var isBoundsScrolling = false
        private var boundsSettleWorkItem: DispatchWorkItem?
        private(set) var isScrollingReported = false
        /// Counts reported scrolls, so a settle check outlived by a newer scroll is dropped.
        private var scrollGeneration = 0

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
            // Re-resolve on the natural AppKit layout boundary until the list is found; an attached
            // observer must not pay for a window walk on every scroll frame.
            guard let observedScrollView, observedScrollView.window === window else {
                attachIfNeeded()
                return
            }
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

            // Legacy mouse-wheel scrolling (and the momentum tail of a trackpad gesture) posts no
            // live-scroll notifications. The clip view moving is the one signal every input shares.
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleClipViewBoundsChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
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
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedScrollView.contentView
                )
            }
            observedScrollView = nil
            attachedWindow = nil
            cachedWindow = nil
            cachedWindowResolvedScrollView = nil
            removeEventMonitor()
            endOwnedPointerInteraction()
            boundsSettleWorkItem?.cancel()
            boundsSettleWorkItem = nil
            isLiveScrolling = false
            isBoundsScrolling = false
            reportScrollEndIfSettled()
        }

        @objc private func handleScrollStart(_ notification: Notification) {
            guard !isLiveScrolling else { return }
            isLiveScrolling = true
            reportScrollStartIfNeeded()
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
            reportScrollEndIfSettled()
        }

        @objc private func handleClipViewBoundsChange(_ notification: Notification) {
            handleClipViewBoundsChange()
        }

        /// Test seam: one clip-view movement. Programmatic scrolls the app performs itself are not
        /// user scrolling and must not retire the hovered row.
        func handleClipViewBoundsChange() {
            if programmaticScrollGate?.isProgrammaticScrollActive == true {
                return
            }
            if !isBoundsScrolling {
                guard isLiveScrolling || isScrollWheelInputCurrent() else { return }
                isBoundsScrolling = true
                reportScrollStartIfNeeded()
            }
            boundsSettleWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.boundsSettleWorkItem = nil
                self.isBoundsScrolling = false
                self.reportScrollEndIfSettled()
            }
            boundsSettleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + boundsSettleInterval, execute: workItem)
        }

        private func reportScrollStartIfNeeded() {
            guard !isScrollingReported else { return }
            isScrollingReported = true
            scrollGeneration &+= 1
            onScrollStart?()
        }

        /// One reported scroll spans both signals: it ends only after the live-scroll gesture
        /// finished and the clip view has been still for `boundsSettleInterval`.
        private func reportScrollEndIfSettled() {
            guard isScrollingReported, !isLiveScrolling, !isBoundsScrolling else { return }
            isScrollingReported = false
            onScrollEnd?()
            logContentShiftAfterScrollEnd()
        }

        /// Evidence for the "list jumps after a fast scroll stops" report: a clip view that moves
        /// after the scroll has settled, while no newer user or programmatic scroll has started,
        /// means a layout correction moved the content. Logs only when it happens.
        private func logContentShiftAfterScrollEnd() {
            guard let scrollView = observedScrollView else { return }
            let clipView = scrollView.contentView
            let originY = clipView.bounds.origin.y
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let firstRow = Self.firstVisibleRow(in: scrollView)
            let generation = scrollGeneration
            for delayMs in [100, 400] {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                    guard let self, !self.isScrollingReported, self.scrollGeneration == generation,
                          self.observedScrollView === scrollView,
                          self.programmaticScrollGate?.isProgrammaticScrollActive != true else { return }
                    let shift = clipView.bounds.origin.y - originY
                    let heightDelta = (scrollView.documentView?.frame.height ?? 0) - documentHeight
                    let rowNow = Self.firstVisibleRow(in: scrollView)
                    guard abs(shift) >= 0.5 || abs(heightDelta) >= 0.5 || firstRow.index != rowNow.index else { return }
                    ScopyLog.ui.info(
                        "Scroll settled: content shifted \(shift, format: .fixed(precision: 1), privacy: .public) pt, document height changed \(heightDelta, format: .fixed(precision: 1), privacy: .public) pt, first visible row \(firstRow.index, privacy: .public) at \(firstRow.top, format: .fixed(precision: 1), privacy: .public) pt (height \(firstRow.height, format: .fixed(precision: 1), privacy: .public)) -> row \(rowNow.index, privacy: .public) at \(rowNow.top, format: .fixed(precision: 1), privacy: .public) pt (height \(rowNow.height, format: .fixed(precision: 1), privacy: .public)), rows \(rowNow.count, privacy: .public), within \(delayMs, privacy: .public) ms of the stop"
                    )
                }
            }
        }

        /// The table row under the top of the clip view, with its frame in document coordinates.
        private static func firstVisibleRow(in scrollView: NSScrollView) -> (index: Int, top: CGFloat, height: CGFloat, count: Int) {
            guard let tableView = scrollView.documentView as? NSTableView else { return (-1, 0, 0, 0) }
            let visible = scrollView.contentView.documentVisibleRect
            let rows = tableView.rows(in: visible)
            guard rows.length > 0 else { return (-1, visible.origin.y, 0, tableView.numberOfRows) }
            let rect = tableView.rect(ofRow: rows.location)
            return (rows.location, rect.origin.y, rect.height, tableView.numberOfRows)
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
            if cachedWindow === window,
               let cachedWindowResolvedScrollView,
               cachedWindowResolvedScrollView.window === window,
               cachedWindowResolvedScrollView.isDescendant(of: contentView),
               Self.isListScrollView(cachedWindowResolvedScrollView) {
                return cachedWindowResolvedScrollView
            }

            let resolved = findFirstListScrollView(in: contentView)
                ?? (allowGenericFallback ? findFirstGenericScrollView(in: contentView) : nil)
            if let resolved, Self.isListScrollView(resolved) {
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
