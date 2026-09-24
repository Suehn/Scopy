import Foundation
import ScopyKit

/// Per-row state that changes with interaction or with each search. It reaches the rows it
/// concerns through `HistoryRowLiveStateFanout`, never through the List body.
struct HistoryRowLiveState: Equatable {
    var isSelected = false
    var evidence: SearchMatchContext?
}

/// Delivers selection and search evidence to the visible rows they concern.
///
/// Rows keep their own copy of `HistoryRowLiveState` and subscribe here while visible, so a
/// selection or evidence change re-renders only the affected rows instead of re-evaluating the
/// whole `List` body and diffing every loaded item.
@MainActor
final class HistoryRowLiveStateFanout {
    private(set) var selectedID: UUID?
    private var evidence: [UUID: SearchMatchContext] = [:]
    private var sinks: [UUID: (HistoryRowLiveState) -> Void] = [:]

    /// Runs after a selection change was fanned out. `follow` is true for keyboard navigation,
    /// where the list scrolls the selected row into view.
    var onSelectionChanged: ((UUID?, Bool) -> Void)?

    func state(for itemID: UUID) -> HistoryRowLiveState {
        HistoryRowLiveState(isSelected: selectedID == itemID, evidence: evidence[itemID])
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

    /// Replaces the evidence map and notifies only registered rows whose evidence changed.
    func replaceEvidence(_ next: [UUID: SearchMatchContext]) {
        let previous = evidence
        evidence = next
        for (itemID, sink) in sinks where previous[itemID] != next[itemID] {
            sink(state(for: itemID))
        }
    }
}
