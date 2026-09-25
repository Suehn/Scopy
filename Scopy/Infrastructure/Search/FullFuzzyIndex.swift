import Foundation

/// Every item's searchable text plus one postings list per distinct character. Postings hold
/// slot numbers as `UInt32`, matching their on-disk width, and stay strictly increasing because
/// a slot is only ever appended, never re-ingested: a changed item tombstones its old slot.
struct FullFuzzyIndex: Sendable {
    var items: [IndexedItem?]
    var idToSlot: [UUID: Int]
    // ASCII-only char index: 128
    var asciiCharPostings: [[UInt32]]
    var nonASCIICharPostings: [Character: [UInt32]]
    var tombstoneCount: Int

    // Scratch that posts each distinct character of one item once; reused across appends.
    private var seenASCII = Array(repeating: false, count: 128)
    private var seenNonASCII = Set<Character>()

    init(reserveSlots: Int) {
        items = []
        idToSlot = [:]
        asciiCharPostings = Array(repeating: [], count: 128)
        nonASCIICharPostings = [:]
        tombstoneCount = 0
        if reserveSlots > 0 {
            items.reserveCapacity(reserveSlots)
            idToSlot.reserveCapacity(reserveSlots)
        }
        seenNonASCII.reserveCapacity(16)
    }

    init(
        items: [IndexedItem?],
        idToSlot: [UUID: Int],
        asciiCharPostings: [[UInt32]],
        nonASCIICharPostings: [Character: [UInt32]],
        tombstoneCount: Int
    ) {
        self.items = items
        self.idToSlot = idToSlot
        self.asciiCharPostings = asciiCharPostings
        self.nonASCIICharPostings = nonASCIICharPostings
        self.tombstoneCount = tombstoneCount
    }

    /// Appends the item as a new slot and posts each of its distinct non-whitespace characters.
    @discardableResult
    mutating func append(_ item: IndexedItem) -> Int {
        let slot = items.count
        items.append(item)
        idToSlot[item.id] = slot

        for i in 0..<seenASCII.count {
            seenASCII[i] = false
        }
        seenNonASCII.removeAll(keepingCapacity: true)

        for ch in item.plainTextLower {
            if ch.isWhitespace { continue }
            if let ascii = ch.asciiValue {
                let idx = Int(ascii)
                if !seenASCII[idx] {
                    seenASCII[idx] = true
                    asciiCharPostings[idx].append(UInt32(slot))
                }
                continue
            }

            if seenNonASCII.insert(ch).inserted {
                nonASCIICharPostings[ch, default: []].append(UInt32(slot))
            }
        }
        return slot
    }
}

enum FullIndexSnapshotSource: String, Sendable {
    case database
    case diskCache
}

struct FullIndexSnapshot: Sendable {
    let index: FullFuzzyIndex
    let source: FullIndexSnapshotSource
}
