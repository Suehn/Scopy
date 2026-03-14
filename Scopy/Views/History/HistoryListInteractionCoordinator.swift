import Foundation

@MainActor
final class HistoryListInteractionCoordinator {
    enum Event {
        case scrollStarted
        case scrollEnded
        case pointerInteractionStarted
        case pointerInteractionEnded
    }

    private static let hoverPreviewCooldownAfterScrollSeconds: CFTimeInterval = 0.25

    private(set) var isScrolling = false
    private(set) var isPointerInteractionActive = false
    private var lastScrollEndedAt: CFTimeInterval = 0
    private var observers: [UUID: (Event) -> Void] = [:]

    var isHoverPreviewSuppressed: Bool {
        if isScrolling || isPointerInteractionActive {
            return true
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - lastScrollEndedAt
        return elapsed < Self.hoverPreviewCooldownAfterScrollSeconds
    }

    func observe(_ observer: @escaping (Event) -> Void) -> HistoryListInteractionObservation {
        let id = UUID()
        observers[id] = observer
        return HistoryListInteractionObservation { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    func beginScrolling() {
        guard !isScrolling else { return }
        isScrolling = true
        notify(.scrollStarted)
    }

    func endScrolling() {
        guard isScrolling else { return }
        isScrolling = false
        lastScrollEndedAt = CFAbsoluteTimeGetCurrent()
        notify(.scrollEnded)
    }

    func beginPointerInteraction() {
        guard !isPointerInteractionActive else { return }
        isPointerInteractionActive = true
        notify(.pointerInteractionStarted)
    }

    func endPointerInteraction() {
        guard isPointerInteractionActive else { return }
        isPointerInteractionActive = false
        notify(.pointerInteractionEnded)
    }

    private func notify(_ event: Event) {
        for observer in observers.values {
            observer(event)
        }
    }
}
