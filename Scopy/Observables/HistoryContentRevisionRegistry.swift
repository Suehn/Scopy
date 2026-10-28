import Foundation
import ScopyKit

struct BoundedHistoryContentRevisionRegistry {
    private struct RevisionEntry {
        let revision: ClipboardItemContentRevision
        let stamp: UInt64
        let mutationSeq: Int64
    }

    private struct DeletionEntry {
        let stamp: UInt64
        let mutationSeq: Int64
    }

    private let capacity: Int
    private var nextStamp: UInt64 = 0
    private var revisionsByItemID: [UUID: RevisionEntry] = [:]
    private var revisionOrder: [(itemID: UUID, stamp: UInt64)] = []
    private var revisionOrderCursor = 0
    private var deletionsByItemID: [UUID: DeletionEntry] = [:]
    private var deletionOrder: [(itemID: UUID, stamp: UInt64)] = []
    private var deletionOrderCursor = 0
    private var protectedItemIDs: Set<UUID> = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var snapshot: HistoryContentRevisionReconciliationSnapshot {
        HistoryContentRevisionReconciliationSnapshot(
            knownRevisionsByItemID: revisionsByItemID.mapValues(\.revision),
            deletedItemIDs: Set(deletionsByItemID.keys)
        )
    }

    #if DEBUG
    var queueCountsForTesting: (revision: Int, deletion: Int) {
        (revisionOrder.count, deletionOrder.count)
    }

    #endif

    /// Active resource owners keep exact revision/deletion evidence for their lifetime. The
    /// remaining entries are a bounded cache; forgetting one says nothing about its existence.
    mutating func protect(itemIDs: Set<UUID>) {
        let released = protectedItemIDs.subtracting(itemIDs)
        protectedItemIDs = itemIDs
        for id in released {
            if let entry = revisionsByItemID[id] { revisionOrder.append((id, entry.stamp)) }
            if let entry = deletionsByItemID[id] { deletionOrder.append((id, entry.stamp)) }
        }
        evictRevisionsIfNeeded()
        evictDeletionsIfNeeded()
        compactQueuesIfNeeded()
    }

    func revision(for itemID: UUID) -> ClipboardItemContentRevision? {
        revisionsByItemID[itemID]?.revision
    }

    func isDeleted(itemID: UUID) -> Bool {
        deletionsByItemID[itemID] != nil
    }

    func acceptsProjection(itemID: UUID) -> Bool {
        !isDeleted(itemID: itemID)
    }

    func mutationSeq(for itemID: UUID) -> Int64? {
        revisionsByItemID[itemID]?.mutationSeq ?? deletionsByItemID[itemID]?.mutationSeq
    }

    func acceptsHistoryChange(itemID: UUID, mutationSeq: Int64) -> Bool {
        self.mutationSeq(for: itemID).map { mutationSeq > $0 } ?? true
    }

    func acceptsSnapshot(itemID: UUID, mutationSeq: Int64) -> Bool {
        guard let known = self.mutationSeq(for: itemID) else { return !isDeleted(itemID: itemID) }
        return mutationSeq > known || (mutationSeq == known && !isDeleted(itemID: itemID))
    }

    @discardableResult
    mutating func merge(
        items: [ClipboardItemDTO],
        mutationSeq: Int64
    ) -> Bool {
        var changed = false
        for item in items {
            if !acceptsHistoryChange(itemID: item.id, mutationSeq: mutationSeq) { continue }
            let revision = ClipboardItemContentRevision.resolve(item: item)
            if deletionsByItemID[item.id] != nil {
                deletionsByItemID.removeValue(forKey: item.id)
                changed = true
            }
            if let existing = revisionsByItemID[item.id],
               existing.revision == revision {
                revisionsByItemID[item.id] = RevisionEntry(
                    revision: revision, stamp: existing.stamp, mutationSeq: mutationSeq
                )
                continue
            }

            let stamp = makeStamp()
            revisionsByItemID[item.id] = RevisionEntry(
                revision: revision,
                stamp: stamp,
                mutationSeq: mutationSeq
            )
            revisionOrder.append((item.id, stamp))
            changed = true
        }
        evictRevisionsIfNeeded()
        compactQueuesIfNeeded()
        return changed
    }

    @discardableResult
    mutating func invalidate(itemID: UUID, mutationSeq: Int64) -> Bool {
        if !acceptsHistoryChange(itemID: itemID, mutationSeq: mutationSeq) { return false }
        let knownVersion = mutationSeq
        var changed = revisionsByItemID.removeValue(forKey: itemID) != nil
        if let previous = deletionsByItemID[itemID] {
            deletionsByItemID[itemID] = DeletionEntry(stamp: previous.stamp, mutationSeq: knownVersion)
        } else {
            let stamp = makeStamp()
            deletionsByItemID[itemID] = DeletionEntry(stamp: stamp, mutationSeq: knownVersion)
            deletionOrder.append((itemID, stamp))
            changed = true
        }
        evictDeletionsIfNeeded()
        compactQueuesIfNeeded()
        return changed
    }
    @discardableResult
    mutating func invalidate(itemIDs: Set<UUID>, mutationSeq: Int64) -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        var newlyDeletedCount = 0
        for itemID in itemIDs {
            if !acceptsHistoryChange(itemID: itemID, mutationSeq: mutationSeq) { continue }
            let knownVersion = mutationSeq
            revisionsByItemID.removeValue(forKey: itemID)
            if let previous = deletionsByItemID[itemID] {
                deletionsByItemID[itemID] = DeletionEntry(stamp: previous.stamp, mutationSeq: knownVersion)
            } else {
                let stamp = makeStamp()
                deletionsByItemID[itemID] = DeletionEntry(stamp: stamp, mutationSeq: knownVersion)
                deletionOrder.append((itemID, stamp))
                newlyDeletedCount += 1
            }
        }
        evictDeletionsIfNeeded()
        compactQueuesIfNeeded()
        return newlyDeletedCount
    }

    private mutating func makeStamp() -> UInt64 {
        nextStamp &+= 1
        return nextStamp
    }

    private mutating func evictRevisionsIfNeeded() {
        while revisionsByItemID.count > capacity + protectedItemIDs.count,
              revisionOrderCursor < revisionOrder.count {
            let candidate = revisionOrder[revisionOrderCursor]
            revisionOrderCursor += 1
            guard !protectedItemIDs.contains(candidate.itemID),
                  revisionsByItemID[candidate.itemID]?.stamp == candidate.stamp else { continue }
            revisionsByItemID.removeValue(forKey: candidate.itemID)
        }
    }

    private mutating func evictDeletionsIfNeeded() {
        while deletionsByItemID.count > capacity + protectedItemIDs.count,
              deletionOrderCursor < deletionOrder.count {
            let candidate = deletionOrder[deletionOrderCursor]
            deletionOrderCursor += 1
            guard !protectedItemIDs.contains(candidate.itemID),
                  deletionsByItemID[candidate.itemID]?.stamp == candidate.stamp else { continue }
            deletionsByItemID.removeValue(forKey: candidate.itemID)
        }
    }

    private mutating func compactQueuesIfNeeded() {
        if revisionOrder.count > capacity * 4 {
            revisionOrder = revisionsByItemID.map { itemID, entry in
                (itemID: itemID, stamp: entry.stamp)
            }.sorted { $0.stamp < $1.stamp }
            revisionOrderCursor = 0
        } else if revisionOrderCursor > capacity,
                  revisionOrderCursor * 2 > revisionOrder.count {
            revisionOrder.removeFirst(revisionOrderCursor)
            revisionOrderCursor = 0
        }
        if deletionOrder.count > capacity * 4 {
            deletionOrder = deletionsByItemID.map { itemID, entry in
                (itemID: itemID, stamp: entry.stamp)
            }.sorted { $0.stamp < $1.stamp }
            deletionOrderCursor = 0
        } else if deletionOrderCursor > capacity,
                  deletionOrderCursor * 2 > deletionOrder.count {
            deletionOrder.removeFirst(deletionOrderCursor)
            deletionOrderCursor = 0
        }
    }
}
