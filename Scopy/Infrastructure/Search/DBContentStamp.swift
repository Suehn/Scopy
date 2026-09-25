import Foundation

/// Logical DB state stamp for disk-cache invalidation. `scopy_meta.mutation_seq` advances
/// exactly once per storage commit, so sequence equality means the cached index still matches
/// the database regardless of file-level churn (WAL growth, checkpoints on quit). `itemCount`
/// (from the same `scopy_meta` row) is a cheap tripwire against a swapped-in database that
/// happens to share the same sequence number.
struct DBContentStamp: Sendable, Equatable {
    let mutationSeq: Int64
    let itemCount: Int
}
