import Foundation

enum ShortQueryIndexSnapshotSource: String, Sendable {
    case database
    case diskCache
}

struct ShortQueryIndexSnapshot: Sendable {
    let index: ShortQueryIndex
    let source: ShortQueryIndexSnapshotSource
}

struct ShortQueryIndex: Sendable {
    // ASCII-only char index: 128
    private static let asciiCharCount = 128
    // ASCII-only bigram index: 128 * 128
    private static let asciiBigramCount = 128 * 128

    private var slotToIDString: [String?] = []
    private var slotToContentHash: [String] = []
    private var slotToType: [ClipboardItemType] = []
    private var slotToPlainTextHash: [String?] = []
    private var slotToNoteHash: [String?] = []
    private var idToSlot: [UUID: Int] = [:]

    private var asciiCharPostings: [[UInt32]] = Array(repeating: [], count: Self.asciiCharCount)
    // Key: (a << 7) | b
    private var asciiBigramPostings: [UInt16: [UInt32]] = [:]

    // Key: (a << 16) | b
    //
    // This covers the hottest non-ASCII short query case (e.g. 2 CJK chars like “数学”),
    // where SQLite `instr()` substring scans become expensive on large text corpora.
    private var nonASCIIBigramPostings: [UInt32: [UInt32]] = [:]

    // Scratch stamps to keep postings unique per ingestion pass.
    private var ingestStamp: UInt32 = 1
    private var seenASCIICharStamp: [UInt32] = Array(repeating: 0, count: Self.asciiCharCount)
    private var seenASCIIBigramStamp: [UInt32] = Array(repeating: 0, count: Self.asciiBigramCount)
    private var seenNonASCIIBigramStamp: [UInt32: UInt32] = [:]

    // Scratch stamps to deduplicate candidate lists at query time.
    private var candidateStamp: UInt32 = 1
    private var slotCandidateStamp: [UInt32] = []

    init(reserveSlots: Int) {
        let reserve = max(0, reserveSlots)
        slotToIDString.reserveCapacity(reserve)
        slotToContentHash.reserveCapacity(reserve)
        slotToType.reserveCapacity(reserve)
        slotToPlainTextHash.reserveCapacity(reserve)
        slotToNoteHash.reserveCapacity(reserve)
        idToSlot.reserveCapacity(reserve)
        slotCandidateStamp.reserveCapacity(reserve)
    }

    func healthStats() -> (slots: Int, live: Int, tombstones: Int) {
        let slots = slotToIDString.count
        let live = idToSlot.count
        let tombstones = max(0, slots - live)
        return (slots, live, tombstones)
    }

    mutating func markDeleted(id: UUID) {
        guard let slot = idToSlot.removeValue(forKey: id),
              slot < slotToIDString.count else {
            return
        }
        slotToIDString[slot] = nil
    }

    mutating func upsert(_ item: ClipboardStoredItem) {
        upsert(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            note: item.note
        )
    }

    mutating func upsert(
        id: UUID,
        type: ClipboardItemType,
        contentHash: String,
        plainText: String,
        note: String?
    ) {
        let newPlainTextHash: String? = (type == .text) ? nil : SearchIndexDiskCache.sha256Hex(Data(plainText.utf8))
        let newNoteHash: String? = note.flatMap { raw in
            guard !raw.isEmpty else { return nil }
            return SearchIndexDiskCache.sha256Hex(Data(raw.utf8))
        }

        if let slot = idToSlot[id],
           slot < slotToIDString.count {
            if slot < slotToContentHash.count,
               slot < slotToType.count,
               slot < slotToPlainTextHash.count,
               slot < slotToNoteHash.count {
                let shouldReindex: Bool
                if type == .text {
                    // For text items, contentHash tracks plain_text changes well; avoid re-ingesting on usage updates.
                    shouldReindex = slotToContentHash[slot] != contentHash || slotToType[slot] != type || slotToNoteHash[slot] != newNoteHash
                } else {
                    // For non-text items, plain_text may change without affecting contentHash (e.g. "[Image: ...]").
                    // Track a separate plainTextHash to avoid re-indexing on pure metadata updates.
                    shouldReindex = slotToContentHash[slot] != contentHash
                        || slotToType[slot] != type
                        || slotToPlainTextHash[slot] != newPlainTextHash
                        || slotToNoteHash[slot] != newNoteHash
                }
                if !shouldReindex { return }
            }

            // Never ingest into an existing slot: postings must remain strictly increasing to keep disk cache valid.
            markDeleted(id: id)
        }

        let slot = slotToIDString.count
        let idString = id.uuidString
        slotToIDString.append(idString)
        slotToContentHash.append(contentHash)
        slotToType.append(type)
        slotToPlainTextHash.append(newPlainTextHash)
        slotToNoteHash.append(newNoteHash)
        idToSlot[id] = slot
        slotCandidateStamp.append(0)

        ingestASCII(plainText: plainText, note: note, slot: slot)
        ingestNonASCIIBigramsUTF16(plainText: plainText, note: note, slot: slot)
    }

    mutating func candidateIDStrings(for tokenLower: String) -> [String] {
        let token = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return [] }
        guard token.canBeConverted(to: .ascii) else { return [] }

        let bytes = Array(token.utf8)
        guard bytes.count == 1 || bytes.count == 2 else { return [] }

        func lowerASCII(_ b: UInt8) -> UInt8 {
            if b >= 65 && b <= 90 { return b | 0x20 }
            return b
        }

        let slots: [UInt32]
        switch bytes.count {
        case 1:
            let c = Int(lowerASCII(bytes[0]))
            guard c >= 0 && c < Self.asciiCharCount else { return [] }
            slots = asciiCharPostings[c]
        case 2:
            let a = Int(lowerASCII(bytes[0]))
            let b = Int(lowerASCII(bytes[1]))
            guard a >= 0 && a < Self.asciiCharCount, b >= 0 && b < Self.asciiCharCount else { return [] }
            let key = UInt16((a << 7) | b)
            slots = asciiBigramPostings[key] ?? []
        default:
            return []
        }

        if slots.isEmpty { return [] }

        return uniqueIDStrings(from: slots)
    }

    mutating func candidateIDStringsForNonASCIIBigram(tokenLower: String) -> [String]? {
        let token = tokenLower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        guard !token.canBeConverted(to: .ascii) else { return nil }

        var units: [UInt16] = []
        units.reserveCapacity(2)
        for cu in token.utf16 {
            units.append(cu)
            if units.count > 2 { break }
        }

        // Only handle the hottest case: 2-UTF16-unit tokens that are fully non-ASCII.
        // Examples:
        // - "数学" => 2 units (CJK), supported.
        // - "😀"  => 2 units (surrogates), supported as a single Unicode scalar.
        guard units.count == 2,
              units[0] >= 128,
              units[1] >= 128 else {
            return nil
        }

        let key = (UInt32(units[0]) << 16) | UInt32(units[1])
        let slots = nonASCIIBigramPostings[key] ?? []
        if slots.isEmpty { return [] }
        return uniqueIDStrings(from: slots)
    }

    private mutating func uniqueIDStrings(from slots: [UInt32]) -> [String] {
        candidateStamp &+= 1
        if candidateStamp == 0 {
            candidateStamp = 1
            slotCandidateStamp = Array(repeating: 0, count: slotCandidateStamp.count)
        }

        var result: [String] = []
        result.reserveCapacity(min(256, slots.count))

        for rawSlot in slots {
            let slot = Int(rawSlot)
            guard slot < slotToIDString.count else { continue }
            if slot < slotCandidateStamp.count {
                if slotCandidateStamp[slot] == candidateStamp { continue }
                slotCandidateStamp[slot] = candidateStamp
            }
            if let id = slotToIDString[slot] {
                result.append(id)
            }
        }
        return result
    }

    private mutating func ingestASCII(plainText: String, note: String?, slot: Int) {
        guard !plainText.isEmpty || (note?.isEmpty == false) else { return }

        ingestStamp &+= 1
        if ingestStamp == 0 {
            ingestStamp = 1
            seenASCIICharStamp = Array(repeating: 0, count: seenASCIICharStamp.count)
            seenASCIIBigramStamp = Array(repeating: 0, count: seenASCIIBigramStamp.count)
            seenNonASCIIBigramStamp.removeAll(keepingCapacity: true)
        }

        @inline(__always)
        func lowerASCII(_ b: UInt8) -> UInt8 {
            if b >= 65 && b <= 90 { return b | 0x20 }
            return b
        }

        func ingestPart(_ text: String) {
            var prev: UInt8? = nil
            for raw in text.utf8 {
                guard raw < 128 else {
                    prev = nil
                    continue
                }

                let b = lowerASCII(raw)

                let c = Int(b)
                if seenASCIICharStamp[c] != ingestStamp {
                    seenASCIICharStamp[c] = ingestStamp
                    asciiCharPostings[c].append(UInt32(slot))
                }

                if let p = prev {
                    let key = UInt16((Int(p) << 7) | Int(b))
                    let idx = Int(key)
                    if seenASCIIBigramStamp[idx] != ingestStamp {
                        seenASCIIBigramStamp[idx] = ingestStamp
                        asciiBigramPostings[key, default: []].append(UInt32(slot))
                    }
                }
                prev = b
            }
        }

        if !plainText.isEmpty {
            ingestPart(plainText)
        }
        if let note, !note.isEmpty {
            ingestPart(note)
        }
    }

    private mutating func ingestNonASCIIBigramsUTF16(plainText: String, note: String?, slot: Int) {
        guard !plainText.isEmpty || (note?.isEmpty == false) else { return }

        ingestStamp &+= 1
        if ingestStamp == 0 {
            ingestStamp = 1
            seenASCIICharStamp = Array(repeating: 0, count: seenASCIICharStamp.count)
            seenASCIIBigramStamp = Array(repeating: 0, count: seenASCIIBigramStamp.count)
            seenNonASCIIBigramStamp.removeAll(keepingCapacity: true)
        }

        func ingestPart(_ text: String) {
            var prev: UInt16? = nil
            for cu in text.utf16 {
                guard cu >= 128 else {
                    prev = nil
                    continue
                }

                if let p = prev {
                    let key = (UInt32(p) << 16) | UInt32(cu)
                    if seenNonASCIIBigramStamp[key] != ingestStamp {
                        seenNonASCIIBigramStamp[key] = ingestStamp
                        nonASCIIBigramPostings[key, default: []].append(UInt32(slot))
                    }
                }
                prev = cu
            }
        }

        if !plainText.isEmpty {
            ingestPart(plainText)
        }
        if let note, !note.isEmpty {
            ingestPart(note)
        }
    }

    var asciiCharPostingsCount: Int {
        asciiCharPostings.count
    }

    func toDiskCache(
        version: Int,
        mutationSeq: Int64
    ) -> SearchIndexDiskCache.ShortQueryIndexDiskCacheV2 {
        var slots: [SearchIndexDiskCache.DiskShortQuerySlot] = []
        slots.reserveCapacity(slotToIDString.count)
        for i in 0..<slotToIDString.count {
            slots.append(
                SearchIndexDiskCache.DiskShortQuerySlot(
                    id: slotToIDString[i],
                    contentHash: slotToContentHash[i],
                    type: slotToType[i].rawValue,
                    plainTextHash: slotToPlainTextHash[i],
                    noteHash: slotToNoteHash[i]
                )
            )
        }

        let asciiBigramKeys = asciiBigramPostings.keys.sorted()
        var asciiBigram: [SearchIndexDiskCache.DiskUInt16Postings] = []
        asciiBigram.reserveCapacity(asciiBigramKeys.count)
        for key in asciiBigramKeys {
            asciiBigram.append(SearchIndexDiskCache.DiskUInt16Postings(key: key, postings: asciiBigramPostings[key] ?? []))
        }

        let nonASCIIBigramKeys = nonASCIIBigramPostings.keys.sorted()
        var nonASCIIBigram: [SearchIndexDiskCache.DiskUInt32Postings] = []
        nonASCIIBigram.reserveCapacity(nonASCIIBigramKeys.count)
        for key in nonASCIIBigramKeys {
            nonASCIIBigram.append(SearchIndexDiskCache.DiskUInt32Postings(key: key, postings: nonASCIIBigramPostings[key] ?? []))
        }

        return SearchIndexDiskCache.ShortQueryIndexDiskCacheV2(
            version: version,
            mutationSeq: mutationSeq,
            slots: slots,
            asciiCharPostings: asciiCharPostings,
            asciiBigramPostings: asciiBigram,
            nonASCIIBigramPostings: nonASCIIBigram
        )
    }

    init?(diskCache: SearchIndexDiskCache.ShortQueryIndexDiskCacheV2) {
        let slotCount = diskCache.slots.count
        self = ShortQueryIndex(reserveSlots: slotCount)

        slotToIDString = diskCache.slots.map(\.id)
        slotToContentHash = diskCache.slots.map(\.contentHash)
        slotToPlainTextHash = diskCache.slots.map(\.plainTextHash)
        slotToNoteHash = diskCache.slots.map(\.noteHash)

        slotToType = []
        slotToType.reserveCapacity(slotCount)

        idToSlot = [:]
        idToSlot.reserveCapacity(slotCount)

        for (slot, entry) in diskCache.slots.enumerated() {
            guard let type = ClipboardItemType(rawValue: entry.type) else { return nil }
            slotToType.append(type)

            if let idString = entry.id {
                guard let id = UUID(uuidString: idString) else { return nil }
                idToSlot[id] = slot
            }
        }

        asciiCharPostings = diskCache.asciiCharPostings

        asciiBigramPostings = [:]
        asciiBigramPostings.reserveCapacity(diskCache.asciiBigramPostings.count)
        for entry in diskCache.asciiBigramPostings {
            if asciiBigramPostings[entry.key] != nil { return nil }
            asciiBigramPostings[entry.key] = entry.postings
        }

        nonASCIIBigramPostings = [:]
        nonASCIIBigramPostings.reserveCapacity(diskCache.nonASCIIBigramPostings.count)
        for entry in diskCache.nonASCIIBigramPostings {
            if nonASCIIBigramPostings[entry.key] != nil { return nil }
            nonASCIIBigramPostings[entry.key] = entry.postings
        }

        ingestStamp = 1
        candidateStamp = 1
        seenNonASCIIBigramStamp = [:]
        seenASCIICharStamp = Array(repeating: 0, count: Self.asciiCharCount)
        seenASCIIBigramStamp = Array(repeating: 0, count: Self.asciiBigramCount)
        slotCandidateStamp = Array(repeating: 0, count: slotCount)
    }
}
