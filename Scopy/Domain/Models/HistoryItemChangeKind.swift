/// Which committed change the row describes; this preserves its search and placement semantics.
public enum HistoryItemChangeKind: Sendable {
    case inserted
    case usage
    case content
    case metadata
    case pin
}
