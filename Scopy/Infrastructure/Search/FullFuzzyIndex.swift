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
    private var seenNonASCII = Set<Character>()
    private var seenPlainScalars = Set<UInt32>()

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
        seenPlainScalars.reserveCapacity(64)
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

        var seenASCII0: UInt64 = 0
        var seenASCII1: UInt64 = 0
        seenNonASCII.removeAll(keepingCapacity: true)

        // The ASCII scorer scans UTF-16, so an ASCII base inside a combining grapheme
        // must also enter its postings list. UTF-8 has the same ASCII units without decoding.
        var hasNonASCII = false
        for byte in item.plainTextLower.utf8 {
            if byte >= 128 {
                hasNonASCII = true
                continue
            }
            if byte == 32 || (9...13).contains(byte) { continue }
            if byte < 64 {
                let bit = UInt64(1) << byte
                if seenASCII0 & bit == 0 {
                    seenASCII0 |= bit
                    asciiCharPostings[Int(byte)].append(UInt32(slot))
                }
            } else {
                let bit = UInt64(1) << (byte - 64)
                if seenASCII1 & bit == 0 {
                    seenASCII1 |= bit
                    asciiCharPostings[Int(byte)].append(UInt32(slot))
                }
            }
        }
        if hasNonASCII {
            // Hash the common single-scalar characters as integers. Only distinct scalars need
            // Character construction and canonical hashing; complex graphemes keep String's rules.
            seenPlainScalars.removeAll(keepingCapacity: true)
            var text = item.plainTextLower
            text.makeContiguousUTF8()
            _ = text.utf8.withContiguousStorageIfAvailable { bytes in
                var cursor = UTF8Text.CharacterCursor(bytes: bytes, text: text, offset: 0)
                while !cursor.isAtEnd {
                    if let scalar = cursor.plainScalar {
                        if scalar >= 128, seenPlainScalars.insert(scalar).inserted,
                           let value = Unicode.Scalar(scalar) {
                            let character = Character(value)
                            if !character.isWhitespace { seenNonASCII.insert(character) }
                        }
                    } else {
                        let character = cursor.character
                        if !character.isWhitespace, character.asciiValue == nil,
                           seenNonASCII.insert(character).inserted {
                            // A short needle may match a scalar inside a longer grapheme.
                            if character.unicodeScalars.count > 1 {
                                for scalar in character.unicodeScalars where !scalar.isASCII {
                                    seenNonASCII.insert(Character(scalar))
                                }
                            }
                        }
                    }
                    cursor.advance()
                }
            }
            for character in seenNonASCII {
                nonASCIICharPostings[character, default: []].append(UInt32(slot))
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
