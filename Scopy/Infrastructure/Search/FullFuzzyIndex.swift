import Foundation

/// Postings hold slot numbers as `UInt32`, matching their on-disk width.
struct FullFuzzyIndex: Sendable {
    var items: [IndexedItem?]
    var idToSlot: [UUID: Int]
    // ASCII-only char index: 128
    var asciiCharPostings: [[UInt32]]
    var nonASCIICharPostings: [Character: [UInt32]]
    var tombstoneCount: Int
}

enum FullIndexSnapshotSource: String, Sendable {
    case database
    case diskCache
}

struct FullIndexSnapshot: Sendable {
    let index: FullFuzzyIndex
    let startDataVersion: Int64
    let endDataVersion: Int64
    let source: FullIndexSnapshotSource
}
