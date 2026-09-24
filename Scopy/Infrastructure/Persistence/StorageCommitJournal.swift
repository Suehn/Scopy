import Foundation
import os

/// What one committed repository write changed, as far as search indexes are concerned.
enum StorageCommittedChange: Sendable {
    /// A row was inserted or changed; carries the committed row without payload bytes.
    case upserted(ClipboardStoredItem)
    case pinChanged(id: UUID, isPinned: Bool)
    case deleted([UUID])
    case clearedUnpinned
    /// A commit that changes no searchable field (for example `size_bytes`).
    case unindexedFields
}

/// Ordered record of committed writes. The repository appends exactly one entry per commit,
/// carrying that commit's `mutation_seq`, from inside the committing actor job, so entry order is
/// commit order. The search engine drains it; a missing sequence number means a commit it can
/// never see (another process, or an overflowed journal) and forces a full index reset.
final class StorageCommitJournal: Sendable {
    struct Entry: Sendable {
        let mutationSeq: Int64
        let change: StorageCommittedChange
    }

    /// Bounds memory when nothing drains; overflowing drops entries and makes the reader reset.
    static let capacity = 1_024

    private struct State {
        var entries: [Entry] = []
        var overflowed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(mutationSeq: Int64, change: StorageCommittedChange) {
        let entry = Entry(mutationSeq: mutationSeq, change: change)
        state.withLock { state in
            guard !state.overflowed else { return }
            if state.entries.count >= Self.capacity {
                state.entries.removeAll()
                state.overflowed = true
                return
            }
            state.entries.append(entry)
        }
    }

    /// Returns and clears the pending entries. `overflowed` means some entries were dropped.
    func drain() -> (entries: [Entry], overflowed: Bool) {
        state.withLock { state in
            let drained = (state.entries, state.overflowed)
            state.entries = []
            state.overflowed = false
            return drained
        }
    }
}
