import Foundation

/// Requested identities and their states in one SQLite read snapshot. Only an absent requested
/// identity is evidence of deletion; rows outside this request were not inspected.
public struct HistoryItemsSnapshot: Sendable {
    public let requestedItemIDs: Set<UUID>
    public let items: [ClipboardItemDTO]
    public let mutationSeq: Int64

    public var missingItemIDs: Set<UUID> {
        requestedItemIDs.subtracting(items.map(\.id))
    }

    public init(requestedItemIDs: Set<UUID>, items: [ClipboardItemDTO], mutationSeq: Int64) {
        self.requestedItemIDs = requestedItemIDs
        self.items = items
        self.mutationSeq = mutationSeq
    }
}
