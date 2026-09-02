import Foundation

/// Delivers keyboard/hover selection to the two rows it concerns.
///
/// Rows keep their own `isKeyboardSelected` state and subscribe here while visible, so a selection
/// change re-renders the previously and newly selected rows instead of re-evaluating the whole
/// `List` body and diffing every loaded item.
@MainActor
final class HistoryRowSelectionFanout {
    private(set) var selectedID: UUID?
    private var sinks: [UUID: (Bool) -> Void] = [:]

    /// Runs after a selection change was fanned out. `follow` is true for keyboard navigation,
    /// where the list scrolls the selected row into view.
    var onSelectionChanged: ((UUID?, Bool) -> Void)?

    func isSelected(_ itemID: UUID) -> Bool {
        selectedID == itemID
    }

    /// Registers the visible row for `itemID` and returns whether it is selected right now.
    @discardableResult
    func register(itemID: UUID, sink: @escaping (Bool) -> Void) -> Bool {
        sinks[itemID] = sink
        return selectedID == itemID
    }

    func unregister(itemID: UUID) {
        sinks[itemID] = nil
    }

    func update(selectedID newID: UUID?, follow: Bool) {
        let oldID = selectedID
        guard oldID != newID else { return }
        selectedID = newID
        if let oldID {
            sinks[oldID]?(false)
        }
        if let newID {
            sinks[newID]?(true)
        }
        onSelectionChanged?(newID, follow)
    }
}
