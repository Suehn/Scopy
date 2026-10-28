import Foundation
import os

/// Facts captured by the repository transaction, before any later writer can replace them.
enum StorageCommittedChange: Sendable {
    case upserted(ClipboardStoredItem, kind: HistoryItemChangeKind)
    /// Disk-size reconciliation changes no searchable field.
    case storageSizesUpdated([ClipboardStoredItem])
    case deleted([UUID])
    /// Clear is also a command barrier; an empty ID list still acknowledges that command.
    case clearedUnpinned(deletedItemIDs: [UUID])
}

/// Bounded commit history shared by independent search and presentation readers. A reader owns
/// its sequence cursor; reading never consumes another reader's changes. Missing history requires
/// a database snapshot, not an approximation from the entries that happen to remain.
final class StorageCommitJournal: Sendable {
    struct Entry: Sendable {
        let mutationSeq: Int64
        let totalCount: Int
        let change: StorageCommittedChange
    }

    enum ReadResult: Sendable {
        case changes(entries: [Entry], through: Int64)
        case resnapshotRequired(through: Int64)
    }

    static let capacity = 1_024
    /// An estimate of retained row and string storage, in addition to the entry-count bound.
    /// A single larger commit advances the sequence but is represented by a gap.
    static let byteBudget = 8 * 1024 * 1024

    private struct BufferedEntry {
        let entry: Entry
        let retainedBytes: Int
    }

    private struct State {
        var entries: [BufferedEntry] = []
        var retainedBytes = 0
        var mutationSeq: Int64 = 0
        var observers: [UUID: AsyncStream<Int64>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var currentMutationSeq: Int64 {
        state.withLock { $0.mutationSeq }
    }

    deinit {
        let observers = state.withLock { state in
            let observers = Array(state.observers.values)
            state.observers.removeAll()
            return observers
        }
        observers.forEach { $0.finish() }
    }

    /// Establishes the database position on open; earlier changes are available only in SQLite.
    func reset(to mutationSeq: Int64) {
        let observers = state.withLock { state in
            state.entries.removeAll()
            state.retainedBytes = 0
            state.mutationSeq = mutationSeq
            return Array(state.observers.values)
        }
        observers.forEach { $0.yield(mutationSeq) }
    }

    func append(mutationSeq: Int64, totalCount: Int, change: StorageCommittedChange) {
        let retainedBytes = Self.retainedByteCount(change)
        let buffered = retainedBytes.map {
            BufferedEntry(
                entry: Entry(mutationSeq: mutationSeq, totalCount: totalCount, change: Self.withoutPayloadBytes(change)),
                retainedBytes: $0
            )
        }
        let observers = state.withLock { state in
            if mutationSeq != state.mutationSeq + 1 || retainedBytes == nil {
                state.entries.removeAll()
                state.retainedBytes = 0
            }
            state.mutationSeq = mutationSeq
            if let buffered {
                state.entries.append(buffered)
                state.retainedBytes += buffered.retainedBytes
                var discarded = 0
                while state.entries.count - discarded > Self.capacity || state.retainedBytes > Self.byteBudget {
                    state.retainedBytes -= state.entries[discarded].retainedBytes
                    discarded += 1
                }
                if discarded > 0 {
                    state.entries.removeFirst(discarded)
                }
            }
            return Array(state.observers.values)
        }
        // Yield outside the lock: cancellation invokes onTermination and removes the observer.
        observers.forEach { $0.yield(mutationSeq) }
    }

    /// A supplied upper bound belongs to the caller's SQLite snapshot. Never return later facts,
    /// or claim coverage when that snapshot's commit has not reached the journal yet.
    func read(after mutationSeq: Int64, through upperBound: Int64? = nil) -> ReadResult {
        state.withLock { state in
            let through = upperBound ?? state.mutationSeq
            guard mutationSeq <= through, through <= state.mutationSeq else {
                return .resnapshotRequired(through: through)
            }
            if mutationSeq == through {
                return .changes(entries: [], through: through)
            }
            guard let start = state.entries.firstIndex(where: { $0.entry.mutationSeq > mutationSeq }),
                  state.entries[start].entry.mutationSeq == mutationSeq + 1 else {
                return .resnapshotRequired(through: through)
            }
            let entries = state.entries[start...].prefix { $0.entry.mutationSeq <= through }.map(\.entry)
            guard entries.last?.mutationSeq == through else {
                return .resnapshotRequired(through: through)
            }
            return .changes(entries: entries, through: through)
        }
    }

    /// Coalesced wakeups, including the current position at registration. Values are only hints:
    /// every wakeup must call `read(after:)`, since concurrent delivery may merge or reorder them.
    func wakeups() -> AsyncStream<Int64> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.removeObserver(id)
            }
            let mutationSeq = state.withLock { state in
                state.observers[id] = continuation
                return state.mutationSeq
            }
            continuation.yield(mutationSeq)
        }
    }

    private func removeObserver(_ id: UUID) {
        _ = state.withLock { state in
            state.observers.removeValue(forKey: id)
        }
    }

    private static func withoutPayloadBytes(_ change: StorageCommittedChange) -> StorageCommittedChange {
        switch change {
        case .upserted(let item, let kind):
            return .upserted(summary(item), kind: kind)
        case .storageSizesUpdated(let items):
            return .storageSizesUpdated(items.map(summary))
        case .deleted, .clearedUnpinned:
            return change
        }
    }

    private static func summary(_ item: ClipboardStoredItem) -> ClipboardStoredItem {
        guard item.rawData != nil else { return item }
        return ClipboardStoredItem(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            note: item.note,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            useCount: item.useCount,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes,
            storageRef: item.storageRef,
            rawData: nil
        )
    }

    /// Rejects oversized facts before making a payload-free copy of a potentially large batch.
    private static func retainedByteCount(_ change: StorageCommittedChange) -> Int? {
        var remaining = byteBudget - MemoryLayout<BufferedEntry>.stride
        switch change {
        case .upserted(let item, _):
            guard consumeBudget(for: item, remaining: &remaining) else { return nil }
        case .storageSizesUpdated(let items):
            for item in items {
                guard consumeBudget(for: item, remaining: &remaining) else { return nil }
            }
        case .deleted(let ids), .clearedUnpinned(let ids):
            guard ids.count <= remaining / MemoryLayout<UUID>.stride else { return nil }
            remaining -= ids.count * MemoryLayout<UUID>.stride
        }
        return byteBudget - remaining
    }

    private static func consumeBudget(for item: ClipboardStoredItem, remaining: inout Int) -> Bool {
        guard MemoryLayout<ClipboardStoredItem>.stride <= remaining else { return false }
        remaining -= MemoryLayout<ClipboardStoredItem>.stride
        for value in [item.contentHash, item.plainText, item.note, item.appBundleID, item.storageRef] {
            let count = value?.utf8.count ?? 0
            guard count <= remaining else { return false }
            remaining -= count
        }
        return true
    }
}
