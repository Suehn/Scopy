import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class HistoryRelativeTimeClock {
    nonisolated static let bucketDuration: TimeInterval = 30

    final class Cancellation {
        private var cancelClosure: (() -> Void)?

        init(_ cancel: @escaping () -> Void) {
            cancelClosure = cancel
        }

        func cancel() {
            guard let cancelClosure else { return }
            self.cancelClosure = nil
            cancelClosure()
        }

        deinit {
            cancel()
        }
    }

    typealias TickAction = @MainActor @Sendable () -> Void
    typealias Scheduler = (_ delay: TimeInterval, _ action: @escaping TickAction) -> Cancellation

    private(set) var bucket: Int64
    @ObservationIgnored private(set) var isRunning = false
    @ObservationIgnored private(set) var isScrolling = false
    @ObservationIgnored private(set) var isWindowVisible = false
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let schedule: Scheduler
    @ObservationIgnored private var scheduledTick: Cancellation?

    init(
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Scheduler = HistoryRelativeTimeClock.productionScheduler
    ) {
        self.now = now
        self.schedule = schedule
        bucket = Self.bucket(for: now())
    }

    var hasScheduledTick: Bool {
        scheduledTick != nil
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshAndSchedule()
    }

    func stop() {
        guard isRunning || scheduledTick != nil else { return }
        isRunning = false
        cancelScheduledTick()
    }

    func scrollDidStart() {
        guard !isScrolling else { return }
        isScrolling = true
        cancelScheduledTick()
    }

    func scrollDidEnd() {
        guard isScrolling else { return }
        isScrolling = false
        refreshAndSchedule()
    }

    func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        if visible {
            refreshAndSchedule()
        } else {
            cancelScheduledTick()
        }
    }

    nonisolated static func bucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / bucketDuration))
    }

    private func refreshAndSchedule() {
        cancelScheduledTick()
        guard isRunning, isWindowVisible, !isScrolling else { return }

        let currentDate = now()
        let nextBucket = Self.bucket(for: currentDate)
        if bucket != nextBucket {
            bucket = nextBucket
        }

        let nextBoundary = (TimeInterval(nextBucket) + 1) * Self.bucketDuration
        let delay = max(0.001, nextBoundary - currentDate.timeIntervalSince1970)
        scheduledTick = schedule(delay) { [weak self] in
            self?.scheduledBoundaryReached()
        }
    }

    private func scheduledBoundaryReached() {
        scheduledTick = nil
        refreshAndSchedule()
    }

    private func cancelScheduledTick() {
        scheduledTick?.cancel()
        scheduledTick = nil
    }

    nonisolated private static func productionScheduler(
        delay: TimeInterval,
        action: @escaping TickAction
    ) -> Cancellation {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return Cancellation {
            task.cancel()
        }
    }
}

private struct HistoryRelativeTimeClockEnvironmentKey: EnvironmentKey {
    static let defaultValue: HistoryRelativeTimeClock? = nil
}

extension EnvironmentValues {
    var historyRelativeTimeClock: HistoryRelativeTimeClock? {
        get { self[HistoryRelativeTimeClockEnvironmentKey.self] }
        set { self[HistoryRelativeTimeClockEnvironmentKey.self] = newValue }
    }
}

/// Bridges the hosting AppKit window's actual visibility into the list clock. The observer owns
/// notification lifetimes and reports hidden/detached windows as paused.
struct HistoryWindowVisibilityObserver: NSViewRepresentable {
    let clock: HistoryRelativeTimeClock

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.clock = clock
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.clock = clock
        nsView.attachToCurrentWindowIfNeeded()
    }

    final class ObserverView: NSView {
        var clock: HistoryRelativeTimeClock? {
            didSet {
                reportVisibility()
            }
        }

        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToCurrentWindowIfNeeded()
        }

        func attachToCurrentWindowIfNeeded() {
            guard observedWindow !== window else {
                reportVisibility()
                return
            }
            detachWindow()
            guard let window else { return }
            observedWindow = window
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowVisibilityChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            reportVisibility()
        }

        @objc private func windowVisibilityChanged(_ notification: Notification) {
            reportVisibility()
        }

        private func reportVisibility() {
            guard let observedWindow else {
                clock?.setWindowVisible(false)
                return
            }
            clock?.setWindowVisible(
                observedWindow.isVisible && observedWindow.occlusionState.contains(.visible)
            )
        }

        private func detachWindow() {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: observedWindow
                )
            }
            observedWindow = nil
            clock?.setWindowVisible(false)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
