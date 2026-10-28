import Foundation
import ScopyKit

/// Committed states received while a history or search snapshot is being read or mounted.
/// Keep one committed state per item, not an event history or an arrival-time epoch.
@MainActor
final class HistoryReadChanges {
    private enum ItemChange {
        case row(ClipboardItemDTO, mutationSeq: Int64)
        case removed(mutationSeq: Int64)

        var mutationSeq: Int64 {
            switch self {
            case .row(_, let version), .removed(let version): return version
            }
        }
    }

    struct Thumbnail {
        let itemID: UUID
        let expectedType: ClipboardItemType
        let expectedContentHash: String
        let path: String
    }

    private let scopedItemIDs: Set<UUID>
    private var changes: [UUID: ItemChange] = [:]
    private var latestTotal: (mutationSeq: Int64, count: Int)?
    private(set) var thumbnails: [UUID: Thumbnail] = [:]

    init(protecting itemIDs: Set<UUID> = []) {
        scopedItemIDs = itemIDs
    }

    var changedItemIDs: Set<UUID> { Set(changes.keys) }
    var protectedItemIDs: Set<UUID> { scopedItemIDs.union(changes.keys) }

    func record(_ commit: CommittedHistoryChange) {
        let version = commit.mutationSeq
        if latestTotal.map({ version > $0.mutationSeq }) ?? true {
            latestTotal = (version, commit.totalCount)
        }
        switch commit.change {
        case .itemsChanged(let items, _):
            for item in items {
                set(.row(item, mutationSeq: version), for: item.id)
            }
        case .itemsRemoved(let ids), .itemsCleared(let ids):
            for id in ids {
                set(.removed(mutationSeq: version), for: id)
            }
        }
    }

    func item(withID id: UUID, after mutationSeq: Int64) -> ClipboardItemDTO? {
        guard case .row(let item, let version) = changes[id], version > mutationSeq else { return nil }
        return item
    }

    func mutationSeq(for id: UUID) -> Int64? { changes[id]?.mutationSeq }

    func record(items: [ClipboardItemDTO], mutationSeq: Int64) {
        for item in items { set(.row(item, mutationSeq: mutationSeq), for: item.id) }
    }

    func recordMissing(itemIDs: Set<UUID>, mutationSeq: Int64) {
        for id in itemIDs { set(.removed(mutationSeq: mutationSeq), for: id) }
    }

    func recordThumbnail(_ thumbnail: Thumbnail) {
        thumbnails[thumbnail.itemID] = thumbnail
    }

    func merge(
        after snapshotVersion: Int64,
        into state: inout HistoryListState,
        accepting acceptsItem: (UUID) -> Bool
    ) {
        for (id, change) in changes where change.mutationSeq > snapshotVersion {
            switch change {
            case .row(let item, let version):
                if acceptsItem(id) { _ = state.upsertRecentItem(item, mutationSeq: version) }
            case .removed(let version):
                _ = state.removeItem(withID: id, mutationSeq: version)
            }
        }
        if let latestTotal, latestTotal.mutationSeq > snapshotVersion {
            state.updateTotalCount(latestTotal.count, mutationSeq: latestTotal.mutationSeq)
        }
    }

    private func set(_ change: ItemChange, for id: UUID) {
        if let previous = changes[id], previous.mutationSeq >= change.mutationSeq {
            // The projection may enrich this same row version with a thumbnail that arrived
            // after hydration. Carry that derivative through replacement-page application.
            guard previous.mutationSeq == change.mutationSeq,
                  case .row(let current, _) = previous, case .row(let incoming, _) = change,
                  current.type == incoming.type, current.contentHash == incoming.contentHash,
                  current.thumbnailPath == nil, incoming.thumbnailPath != nil else { return }
        }
        changes[id] = change
    }
}
