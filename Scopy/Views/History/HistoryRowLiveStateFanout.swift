import Foundation
import ScopyKit

/// Per-row state that changes with interaction or with each search. It reaches the rows it
/// concerns through `HistoryRowLiveStateFanout`, never through the List body.
struct HistoryRowLiveState: Equatable {
    var isSelected = false
    var evidence: SearchMatchContext?
    /// The hover popover this row presents, if any (at most one row at a time).
    var presentedPreview: HoverPreviewPopoverKind?
    /// The ⌘1–9 slot shown in place of the time while ⌘ is held; only the first nine
    /// displayed rows have one.
    var quickSlot: Int?
}

/// Delivers selection, search evidence and the presented hover popover to the visible rows they
/// concern.
///
/// Rows keep their own copy of `HistoryRowLiveState` and subscribe here while visible, so a
/// selection or evidence change re-renders only the affected rows instead of re-evaluating the
/// whole `List` body and diffing every loaded item.
@MainActor
final class HistoryRowLiveStateFanout {
    /// Identifies one mounted row, independently of the item's identity. Pinning or list
    /// virtualization can mount its replacement before the old row disappears.
    struct RegistrationToken: Equatable {
        let itemID: UUID
        private let identity = UUID()

        init(itemID: UUID) {
            self.itemID = itemID
        }
    }

    private struct Registration {
        let token: RegistrationToken
        let sink: (HistoryRowLiveState) -> Void
    }

    private(set) var selectedID: UUID?
    private(set) var presentedPreview: HoverPreviewPopoverState?
    private var evidence: [UUID: SearchMatchContext] = [:]
    private var quickSlots: [UUID: Int] = [:]
    private var registrations: [UUID: Registration] = [:]

    /// Runs after a selection change was fanned out. `follow` is true for keyboard navigation,
    /// where the list scrolls the selected row into view.
    var onSelectionChanged: ((UUID?, Bool) -> Void)?

    func state(for itemID: UUID) -> HistoryRowLiveState {
        HistoryRowLiveState(
            isSelected: selectedID == itemID,
            evidence: evidence[itemID],
            presentedPreview: presentedPreview?.itemID == itemID ? presentedPreview?.kind : nil,
            quickSlot: quickSlots[itemID]
        )
    }

    /// Registers this visible row and returns its state right now.
    @discardableResult
    func register(
        _ token: RegistrationToken,
        sink: @escaping (HistoryRowLiveState) -> Void
    ) -> HistoryRowLiveState {
        registrations[token.itemID] = Registration(token: token, sink: sink)
        return state(for: token.itemID)
    }

    func unregister(_ token: RegistrationToken) {
        guard registrations[token.itemID]?.token == token else { return }
        registrations[token.itemID] = nil
    }

    func update(selectedID newID: UUID?, follow: Bool) {
        let oldID = selectedID
        guard oldID != newID else { return }
        selectedID = newID
        if let oldID, let registration = registrations[oldID] {
            registration.sink(state(for: oldID))
        }
        if let newID, let registration = registrations[newID] {
            registration.sink(state(for: newID))
        }
        onSelectionChanged?(newID, follow)
    }

    /// Moves the hover popover; only the row losing it and the row gaining it are notified.
    func updatePresentedPreview(_ next: HoverPreviewPopoverState?) {
        let previous = presentedPreview
        guard previous != next else { return }
        presentedPreview = next
        if let previousID = previous?.itemID, let registration = registrations[previousID] {
            registration.sink(state(for: previousID))
        }
        if let nextID = next?.itemID, nextID != previous?.itemID, let registration = registrations[nextID] {
            registration.sink(state(for: nextID))
        }
    }

    #if DEBUG
    /// Evidence maps applied so far; each one walks every registered row.
    private(set) var evidenceReplacementCountForTesting = 0
    #endif

    /// Replaces the evidence map and notifies only registered rows whose evidence changed.
    func replaceEvidence(_ next: [UUID: SearchMatchContext]) {
        #if DEBUG
        evidenceReplacementCountForTesting += 1
        #endif
        let previous = evidence
        evidence = next
        for (itemID, registration) in registrations where previous[itemID] != next[itemID] {
            registration.sink(state(for: itemID))
        }
    }

    /// Replaces the ⌘n slots (empty when ⌘ is released) and notifies only the rows whose slot changed.
    func updateQuickSlots(_ next: [UUID: Int]) {
        let previous = quickSlots
        guard previous != next else { return }
        quickSlots = next
        for (itemID, registration) in registrations where previous[itemID] != next[itemID] {
            registration.sink(state(for: itemID))
        }
    }
}
