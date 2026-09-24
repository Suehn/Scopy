import Foundation
import ScopyKit

/// Per-row state that changes with interaction or with each search. It reaches the rows it
/// concerns through `HistoryRowLiveStateFanout`, never through the List body.
struct HistoryRowLiveState: Equatable {
    var isSelected = false
    var evidence: SearchMatchContext?
    /// The hover popover this row presents, if any (at most one row at a time).
    var presentedPreview: HoverPreviewPopoverKind?
}

/// Delivers selection, search evidence and the presented hover popover to the visible rows they
/// concern.
///
/// Rows keep their own copy of `HistoryRowLiveState` and subscribe here while visible, so a
/// selection or evidence change re-renders only the affected rows instead of re-evaluating the
/// whole `List` body and diffing every loaded item.
@MainActor
final class HistoryRowLiveStateFanout {
    private(set) var selectedID: UUID?
    private(set) var presentedPreview: HoverPreviewPopoverState?
    private var evidence: [UUID: SearchMatchContext] = [:]
    private var sinks: [UUID: (HistoryRowLiveState) -> Void] = [:]

    /// Runs after a selection change was fanned out. `follow` is true for keyboard navigation,
    /// where the list scrolls the selected row into view.
    var onSelectionChanged: ((UUID?, Bool) -> Void)?

    func state(for itemID: UUID) -> HistoryRowLiveState {
        HistoryRowLiveState(
            isSelected: selectedID == itemID,
            evidence: evidence[itemID],
            presentedPreview: presentedPreview?.itemID == itemID ? presentedPreview?.kind : nil
        )
    }

    /// Registers the visible row for `itemID` and returns its state right now.
    @discardableResult
    func register(itemID: UUID, sink: @escaping (HistoryRowLiveState) -> Void) -> HistoryRowLiveState {
        sinks[itemID] = sink
        return state(for: itemID)
    }

    func unregister(itemID: UUID) {
        sinks[itemID] = nil
    }

    func update(selectedID newID: UUID?, follow: Bool) {
        let oldID = selectedID
        guard oldID != newID else { return }
        selectedID = newID
        if let oldID, let sink = sinks[oldID] {
            sink(state(for: oldID))
        }
        if let newID, let sink = sinks[newID] {
            sink(state(for: newID))
        }
        onSelectionChanged?(newID, follow)
    }

    /// Moves the hover popover; only the row losing it and the row gaining it are notified.
    func updatePresentedPreview(_ next: HoverPreviewPopoverState?) {
        let previous = presentedPreview
        guard previous != next else { return }
        presentedPreview = next
        if let previousID = previous?.itemID, let sink = sinks[previousID] {
            sink(state(for: previousID))
        }
        if let nextID = next?.itemID, nextID != previous?.itemID, let sink = sinks[nextID] {
            sink(state(for: nextID))
        }
    }

    /// Replaces the evidence map and notifies only registered rows whose evidence changed.
    func replaceEvidence(_ next: [UUID: SearchMatchContext]) {
        let previous = evidence
        evidence = next
        for (itemID, sink) in sinks where previous[itemID] != next[itemID] {
            sink(state(for: itemID))
        }
    }
}
