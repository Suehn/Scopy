import Foundation

/// Compact little-endian encoding for the search index disk caches.
///
/// The property-list encoding decoded a 16 MB short-index cache in about 2.9 s at launch and the
/// 26 MB full-index cache in about 1.9 s on the first fuzzy search; strings and postings written
/// as raw bytes decode in tens of milliseconds. Every read is bounds-checked and a malformed
/// payload yields `nil`, which the callers treat as a cache miss.
enum SearchIndexBinaryCodec {
    static let magic: UInt32 = 0x5343_4958 // "SCIX"
    static let shortFormat: UInt32 = 1
    static let fullFormat: UInt32 = 2

    struct Writer {
        private(set) var data = Data()

        init(capacity: Int) {
            data.reserveCapacity(capacity)
        }

        mutating func u8(_ value: UInt8) {
            data.append(value)
        }

        mutating func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        mutating func i64(_ value: Int64) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        mutating func f64(_ value: Double) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        /// UTF-8 bytes with a length prefix; `nil` is written as the sentinel length.
        mutating func string(_ value: String?) {
            guard let value else {
                u32(UInt32.max)
                return
            }
            var copy = value
            copy.withUTF8 { bytes in
                u32(UInt32(bytes.count))
                data.append(contentsOf: bytes)
            }
        }

        mutating func postings(_ values: [Int]) {
            u32(UInt32(values.count))
            values.withUnsafeBufferPointer { buffer in
                for value in buffer {
                    var little = Int32(truncatingIfNeeded: value).littleEndian
                    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
                }
            }
        }
    }

    struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool {
            offset == data.endIndex
        }

        private mutating func take(_ count: Int) -> Data? {
            guard count >= 0, data.endIndex - offset >= count else { return nil }
            let slice = data[offset..<(offset + count)]
            offset += count
            return slice
        }

        mutating func u8() -> UInt8? {
            take(1)?.first
        }

        mutating func u32() -> UInt32? {
            guard let slice = take(4) else { return nil }
            return slice.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        mutating func i64() -> Int64? {
            guard let slice = take(8) else { return nil }
            return slice.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }.littleEndian
        }

        mutating func f64() -> Double? {
            guard let slice = take(8) else { return nil }
            return Double(bitPattern: slice.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
        }

        /// A count that must fit the remaining bytes at `bytesPerElement` each.
        mutating func count(bytesPerElement: Int) -> Int? {
            guard let raw = u32(), raw != UInt32.max else { return nil }
            let count = Int(raw)
            guard count <= (data.endIndex - offset) / max(1, bytesPerElement) else { return nil }
            return count
        }

        /// Returns `.some(nil)` for the nil sentinel, `nil` for a malformed string.
        mutating func string() -> String?? {
            guard let raw = u32() else { return nil }
            if raw == UInt32.max { return .some(nil) }
            guard let slice = take(Int(raw)) else { return nil }
            guard let value = String(bytes: slice, encoding: .utf8) else { return nil }
            return .some(value)
        }

        mutating func postings() -> [Int]? {
            guard let count = count(bytesPerElement: 4), let slice = take(count * 4) else { return nil }
            return slice.withUnsafeBytes { raw -> [Int] in
                [Int](unsafeUninitializedCapacity: count) { buffer, initialized in
                    for index in 0..<count {
                        buffer[index] = Int(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: Int32.self)))
                    }
                    initialized = count
                }
            }
        }
    }

    // MARK: - Short-query index

    static func encodeShort(_ cache: SearchIndexDiskCache.ShortQueryIndexDiskCacheV2) -> Data {
        var writer = Writer(capacity: 1 << 20)
        writer.u32(magic)
        writer.u32(shortFormat)
        writer.u32(UInt32(cache.version))
        writer.i64(cache.mutationSeq)
        writer.u32(UInt32(cache.slots.count))
        for slot in cache.slots {
            writer.string(slot.id)
            writer.string(slot.contentHash)
            writer.string(slot.type)
            writer.string(slot.plainTextHash)
            writer.string(slot.noteHash)
        }
        writer.u32(UInt32(cache.asciiCharPostings.count))
        for postings in cache.asciiCharPostings {
            writer.postings(postings)
        }
        writer.u32(UInt32(cache.asciiBigramPostings.count))
        for entry in cache.asciiBigramPostings {
            writer.u32(UInt32(entry.key))
            writer.postings(entry.postings)
        }
        writer.u32(UInt32(cache.nonASCIIBigramPostings.count))
        for entry in cache.nonASCIIBigramPostings {
            writer.u32(entry.key)
            writer.postings(entry.postings)
        }
        return writer.data
    }

    /// Reads only the header: format, cache version and mutation sequence.
    static func header(of data: Data) -> (format: UInt32, version: Int, mutationSeq: Int64)? {
        var reader = Reader(data)
        guard reader.u32() == magic, let format = reader.u32(), let version = reader.u32(),
              let mutationSeq = reader.i64() else { return nil }
        return (format, Int(version), mutationSeq)
    }

    static func decodeShort(_ data: Data) -> SearchIndexDiskCache.ShortQueryIndexDiskCacheV2? {
        var reader = Reader(data)
        guard reader.u32() == magic, reader.u32() == shortFormat,
              let version = reader.u32(), let mutationSeq = reader.i64() else { return nil }

        guard let slotCount = reader.count(bytesPerElement: 5 * 4) else { return nil }
        var slots: [SearchIndexDiskCache.DiskShortQuerySlot] = []
        slots.reserveCapacity(slotCount)
        for _ in 0..<slotCount {
            guard let id = reader.string(), let contentHash = reader.string(), let type = reader.string(),
                  let plainTextHash = reader.string(), let noteHash = reader.string() else { return nil }
            guard let contentHash, let type else { return nil }
            slots.append(SearchIndexDiskCache.DiskShortQuerySlot(
                id: id, contentHash: contentHash, type: type, plainTextHash: plainTextHash, noteHash: noteHash
            ))
        }

        guard let asciiCount = reader.count(bytesPerElement: 4) else { return nil }
        var asciiCharPostings: [[Int]] = []
        asciiCharPostings.reserveCapacity(asciiCount)
        for _ in 0..<asciiCount {
            guard let postings = reader.postings() else { return nil }
            asciiCharPostings.append(postings)
        }

        guard let bigramCount = reader.count(bytesPerElement: 8) else { return nil }
        var asciiBigramPostings: [SearchIndexDiskCache.DiskUInt16Postings] = []
        asciiBigramPostings.reserveCapacity(bigramCount)
        for _ in 0..<bigramCount {
            guard let key = reader.u32(), key <= UInt32(UInt16.max), let postings = reader.postings() else { return nil }
            asciiBigramPostings.append(SearchIndexDiskCache.DiskUInt16Postings(key: UInt16(key), postings: postings))
        }

        guard let nonASCIICount = reader.count(bytesPerElement: 8) else { return nil }
        var nonASCIIBigramPostings: [SearchIndexDiskCache.DiskUInt32Postings] = []
        nonASCIIBigramPostings.reserveCapacity(nonASCIICount)
        for _ in 0..<nonASCIICount {
            guard let key = reader.u32(), let postings = reader.postings() else { return nil }
            nonASCIIBigramPostings.append(SearchIndexDiskCache.DiskUInt32Postings(key: key, postings: postings))
        }
        guard reader.isAtEnd else { return nil }

        return SearchIndexDiskCache.ShortQueryIndexDiskCacheV2(
            version: Int(version),
            mutationSeq: mutationSeq,
            slots: slots,
            asciiCharPostings: asciiCharPostings,
            asciiBigramPostings: asciiBigramPostings,
            nonASCIIBigramPostings: nonASCIIBigramPostings
        )
    }

    // MARK: - Full fuzzy index

    struct FullItem: Sendable {
        let id: String
        let type: String
        let contentHash: String
        let plainTextLower: String
        let appBundleID: String?
        let createdAt: TimeInterval
        let lastUsedAt: TimeInterval
        let useCount: Int
        let isPinned: Bool
        let sizeBytes: Int
        let storageRef: String?
    }

    struct FullPayload: Sendable {
        let version: Int
        let mutationSeq: Int64
        let items: [FullItem?]
        let asciiCharPostings: [[Int]]
        let nonASCIICharPostings: [(key: String, postings: [Int])]
    }

    static func encodeFull(
        version: Int,
        mutationSeq: Int64,
        items: [FullItem?],
        asciiCharPostings: [[Int]],
        nonASCIICharPostings: [(key: String, postings: [Int])]
    ) -> Data {
        var writer = Writer(capacity: 1 << 22)
        writer.u32(magic)
        writer.u32(fullFormat)
        writer.u32(UInt32(version))
        writer.i64(mutationSeq)
        writer.u32(UInt32(items.count))
        for item in items {
            guard let item else {
                writer.u8(0)
                continue
            }
            writer.u8(1)
            writer.string(item.id)
            writer.string(item.type)
            writer.string(item.contentHash)
            writer.string(item.plainTextLower)
            writer.string(item.appBundleID)
            writer.f64(item.createdAt)
            writer.f64(item.lastUsedAt)
            writer.i64(Int64(item.useCount))
            writer.u8(item.isPinned ? 1 : 0)
            writer.i64(Int64(item.sizeBytes))
            writer.string(item.storageRef)
        }
        writer.u32(UInt32(asciiCharPostings.count))
        for postings in asciiCharPostings {
            writer.postings(postings)
        }
        writer.u32(UInt32(nonASCIICharPostings.count))
        for entry in nonASCIICharPostings {
            writer.string(entry.key)
            writer.postings(entry.postings)
        }
        return writer.data
    }

    static func decodeFull(_ data: Data) -> FullPayload? {
        var reader = Reader(data)
        guard reader.u32() == magic, reader.u32() == fullFormat,
              let version = reader.u32(), let mutationSeq = reader.i64() else { return nil }

        guard let itemCount = reader.count(bytesPerElement: 1) else { return nil }
        var items: [FullItem?] = []
        items.reserveCapacity(itemCount)
        for _ in 0..<itemCount {
            guard let present = reader.u8() else { return nil }
            if present == 0 {
                items.append(nil)
                continue
            }
            guard present == 1,
                  let id = reader.string(), let type = reader.string(), let contentHash = reader.string(),
                  let plainTextLower = reader.string(), let appBundleID = reader.string(),
                  let createdAt = reader.f64(), let lastUsedAt = reader.f64(), let useCount = reader.i64(),
                  let pinned = reader.u8(), let sizeBytes = reader.i64(), let storageRef = reader.string()
            else { return nil }
            guard let id, let type, let contentHash, let plainTextLower, pinned <= 1 else { return nil }
            items.append(FullItem(
                id: id, type: type, contentHash: contentHash, plainTextLower: plainTextLower,
                appBundleID: appBundleID, createdAt: createdAt, lastUsedAt: lastUsedAt,
                useCount: Int(useCount), isPinned: pinned == 1, sizeBytes: Int(sizeBytes), storageRef: storageRef
            ))
        }

        guard let asciiCount = reader.count(bytesPerElement: 4) else { return nil }
        var asciiCharPostings: [[Int]] = []
        asciiCharPostings.reserveCapacity(asciiCount)
        for _ in 0..<asciiCount {
            guard let postings = reader.postings() else { return nil }
            asciiCharPostings.append(postings)
        }

        guard let nonASCIICount = reader.count(bytesPerElement: 8) else { return nil }
        var nonASCII: [(key: String, postings: [Int])] = []
        nonASCII.reserveCapacity(nonASCIICount)
        for _ in 0..<nonASCIICount {
            guard let key = reader.string(), let key, let postings = reader.postings() else { return nil }
            nonASCII.append((key: key, postings: postings))
        }
        guard reader.isAtEnd else { return nil }

        return FullPayload(
            version: Int(version),
            mutationSeq: mutationSeq,
            items: items,
            asciiCharPostings: asciiCharPostings,
            nonASCIICharPostings: nonASCII
        )
    }
}
