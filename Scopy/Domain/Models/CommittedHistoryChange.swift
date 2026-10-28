/// A history change and its SQLite transaction position. The publisher preserves commit order;
/// consumers compare this position with the snapshot that supplied each part of their state.
public struct CommittedHistoryChange: Sendable {
    public let mutationSeq: Int64
    public let totalCount: Int
    public let change: HistoryChange

    public init(mutationSeq: Int64, totalCount: Int, change: HistoryChange) {
        self.mutationSeq = mutationSeq
        self.totalCount = totalCount
        self.change = change
    }
}
