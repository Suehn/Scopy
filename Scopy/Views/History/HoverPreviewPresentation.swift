import Foundation
import QuartzCore

/// List-level hover popover bookkeeping, held by reference so scheduling or dismissing a popover
/// never invalidates the List body. The active popover itself lives in
/// `HistoryRowLiveStateFanout`, which re-renders only the row losing it and the row gaining it.
@MainActor
final class HoverPreviewPresentation {
    static let reopenCooldownSeconds: CFTimeInterval = 0.25

    /// A popover waiting for the next run-loop turn or for the reopen cooldown.
    var pending: HoverPreviewPopoverState?
    private var lastDismissed: (itemID: UUID, at: CFTimeInterval)?

    func recordDismiss(itemID: UUID, at time: CFTimeInterval = CACurrentMediaTime()) {
        lastDismissed = (itemID, time)
    }

    /// Re-presenting the popover that was just dismissed waits out the cooldown, so a system
    /// dismissal racing a re-hover does not flash it closed and open.
    func reopenDelaySeconds(for itemID: UUID, now: CFTimeInterval = CACurrentMediaTime()) -> CFTimeInterval {
        guard let lastDismissed, lastDismissed.itemID == itemID else { return 0 }
        return max(0, Self.reopenCooldownSeconds - (now - lastDismissed.at))
    }
}
