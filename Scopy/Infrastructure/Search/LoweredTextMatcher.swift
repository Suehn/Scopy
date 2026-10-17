import Foundation

/// Finds a lowercased needle in UTF-8 text as if the text had been lowercased first, without decoding,
/// lowercasing, or copying it. Offsets are UTF-16 units of `text.lowercased()`, the scorer's unit.
/// It answers only where that provably equals the `String` matcher; elsewhere it returns `.undecided`
/// and the caller runs the `String` matcher on that text.
struct LoweredTextMatcher: Sendable {
    enum Outcome: Equatable {
        case hit(utf16Offset: Int)
        case miss
        case undecided
    }

    private enum Needle: Sendable {
        /// ASCII bytes over the lowercased code units. Whole-character matching accepts only a hit
        /// whose neighbouring units are ASCII, where code units and characters agree.
        case ascii(bytes: [UInt8], failure: [Int], wholeCharacters: Bool)
        /// Non-ASCII scalars over code units: every UTF-8 spelling whose lowercase is the needle.
        case scalars(spellings: [[UInt8]])
        /// The needle's composed form as whole characters. Plain starters are already composed, so an
        /// equivalent match made of them is a spelling; any other equivalent contains a hazard, a scalar
        /// that decomposes into the needle's own scalars.
        case canonical(spellings: [[UInt8]], hazards: [[UInt8]])
    }

    private let needle: Needle

    /// Code-unit search, the scorer's rule for one- and two-character needles that are stable under
    /// normalization.
    init?(codeUnitsOf needleLower: String) {
        guard !needleLower.isEmpty else { return nil }
        if needleLower.utf8.allSatisfy({ $0 < 128 }) {
            let bytes = Array(needleLower.utf8)
            needle = .ascii(bytes: bytes, failure: Self.failureTable(bytes), wholeCharacters: false)
            return
        }
        // U+FFFD also stands for invalid UTF-8.
        guard needleLower.unicodeScalars.allSatisfy({
            !$0.isASCII && $0 != "\u{FFFD}" && !$0.properties.changesWhenLowercased
        }), let spellings = Self.spellings(of: needleLower.unicodeScalars) else { return nil }
        needle = .scalars(spellings: spellings)
    }

    /// `String.range(of:)`: canonically equivalent whole characters.
    init?(charactersOf needleLower: String) {
        guard !needleLower.isEmpty else { return nil }
        if needleLower.utf8.allSatisfy({ $0 < 128 }) {
            // Controls can join (CR LF), and ";" and "`" have canonical singletons (U+037E, U+1FEF)
            // that only the String matcher equates.
            guard needleLower.utf8.allSatisfy({ (0x20...0x7E).contains($0) && $0 != 0x3B && $0 != 0x60 }) else {
                return nil
            }
            let bytes = Array(needleLower.utf8)
            needle = .ascii(bytes: bytes, failure: Self.failureTable(bytes), wholeCharacters: true)
            return
        }
        let composed = needleLower.precomposedStringWithCanonicalMapping.unicodeScalars
        guard composed.allSatisfy({ Self.isPlainStarter($0.value) && !$0.properties.changesWhenLowercased }),
              let spellings = Self.spellings(of: composed) else { return nil }
        let decomposed = Set(needleLower.decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        let hazards = Set(decomposed.filter { !Self.isPlainStarter($0) } + ExpansionTable.scalars(madeOf: decomposed))
        needle = .canonical(
            spellings: spellings,
            hazards: hazards.compactMap { Unicode.Scalar($0).map { Array(String($0).utf8) } }
        )
    }

    /// Every UTF-8 spelling whose lowercase is `scalars`, or nil for too many or for a scalar that
    /// lowercasing also produces inside a longer mapping (the dot of İ).
    private static func spellings(of scalars: String.UnicodeScalarView) -> [[UInt8]]? {
        let table = LowercaseTable.shared
        var spellings: [[UInt8]] = [[]]
        for scalar in scalars {
            guard scalar.isASCII || !table.partOfLongerLowercase.contains(scalar.value) else { return nil }
            var sources = [scalar] + (table.sources[scalar.value] ?? [])
            if (0x61...0x7A).contains(scalar.value) {
                sources.append(Unicode.Scalar(UInt8(scalar.value) - 0x20))
            }
            spellings = spellings.flatMap { prefix in sources.map { prefix + Array(String($0).utf8) } }
            guard spellings.count <= 8 else { return nil }
        }
        return spellings
    }

    func firstMatch(in text: UnsafeBufferPointer<UInt8>) -> Outcome {
        switch needle {
        case .ascii(let bytes, let failure, let wholeCharacters):
            return Self.matchASCII(in: text, needle: bytes, failure: failure, wholeCharacters: wholeCharacters)
        case .scalars(let spellings):
            // UTF-8 never starts a scalar inside another, so a byte hit is a scalar hit.
            guard let start = Self.firstIndex(ofAny: spellings, in: text) else { return .miss }
            guard let offset = Self.loweredUTF16Length(of: UnsafeBufferPointer(rebasing: text[..<start])) else {
                return .undecided
            }
            return .hit(utf16Offset: offset)
        case .canonical(let spellings, let hazards):
            let start = Self.firstIndex(ofAny: spellings, in: text)
            if Self.firstIndex(ofAny: hazards, in: text, before: start ?? text.count) != nil { return .undecided }
            guard let start else { return .miss }
            let prefix = UnsafeBufferPointer(rebasing: text[..<start])
            // The hit must not share a character with its neighbours.
            guard let offset = Self.loweredUTF16Length(of: prefix),
                  start == 0 || Self.lastScalar(of: prefix).map(Self.isPlainStarter) == true else { return .undecided }
            let end = start + (spellings.first { Self.matches($0, in: text, at: start) }?.count ?? 0)
            if end < text.count {
                guard let (next, _) = Self.decode(text, at: end), Self.isPlainStarter(next) else { return .undecided }
            }
            return .hit(utf16Offset: offset)
        }
    }

    /// Decides on a native string's UTF-8 in place.
    func firstMatch(in text: String) -> Outcome {
        text.utf8.withContiguousStorageIfAvailable { firstMatch(in: $0) } ?? .undecided
    }

    /// The UTF-16 length of `text.lowercased()`, or nil for invalid UTF-8.
    static func loweredUTF16Length(of text: UnsafeBufferPointer<UInt8>) -> Int? {
        let table = LowercaseTable.shared
        var units = 0
        var index = 0
        while index < text.count {
            guard let (end, skippedUnits) = skipPlainText(in: text, from: index, stop: nil, table: table) else {
                return nil
            }
            units += skippedUnits
            index = end
            if text[index] < 128 {
                units += 1
                index += 1
                continue
            }
            guard let width = validatedWidth(in: text, at: index) else { return nil }
            units += table.special(in: text, at: index, width: width)?.count ?? (width == 4 ? 2 : 1)
            index += width
        }
        return units
    }

    // MARK: - Skipping

    /// Skips well-formed text from the scalar boundary `start` to the first special scalar or byte
    /// that can begin the ASCII `stop` (either case), 16 bytes per step. Outside special scalars,
    /// lowercasing keeps every scalar's UTF-16 length and adds no ASCII unit, so the skipped units
    /// are the non-continuation bytes plus one per four-byte lead. Returns the scalar boundary
    /// reached, before the last 17 bytes, and the units before it; nil for malformed bytes before it.
    private static func skipPlainText(
        in text: UnsafeBufferPointer<UInt8>,
        from start: Int,
        stop: UInt8?,
        table: LowercaseTable
    ) -> (end: Int, units: Int)? {
        // The three bytes before `start` belong to whole scalars, so they demand no continuation.
        guard start >= 3, start + 17 <= text.count, let base = text.baseAddress else { return (start, 0) }
        // Only vector-to-vector comparisons compile to single instructions; a scalar operand
        // compares lane by lane.
        func splat(_ byte: UInt8) -> Bytes { Bytes(repeating: byte) }
        let raw = UnsafeRawPointer(base)
        // 0xFF never occurs in UTF-8.
        let stopLower = splat(stop ?? 0xFF)
        let stopUpper = splat(stop.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 } ?? 0xFF)
        let x80 = splat(0x80), x90 = splat(0x90), xA0 = splat(0xA0), xC0 = splat(0xC0), xC2 = splat(0xC2)
        let xE0 = splat(0xE0), xED = splat(0xED), xF0 = splat(0xF0), xF4 = splat(0xF4), xF5 = splat(0xF5)
        var block = start
        var units = 0
        // Per-lane units of at most seven blocks, two per lane each, so no byte lane overflows.
        var pendingUnits = Bytes()
        var pendingBlocks = 0
        while block + 17 <= text.count {
            let bytes = raw.loadUnaligned(fromByteOffset: block, as: Bytes.self)
            let next = raw.loadUnaligned(fromByteOffset: block + 1, as: Bytes.self)
            let previous1 = raw.loadUnaligned(fromByteOffset: block - 1, as: Bytes.self)
            let previous2 = raw.loadUnaligned(fromByteOffset: block - 2, as: Bytes.self)
            let previous3 = raw.loadUnaligned(fromByteOffset: block - 3, as: Bytes.self)

            var stops = (bytes .== stopLower) .| (bytes .== stopUpper)
            for prefix in table.specialPrefixes {
                stops .|= (bytes .== prefix.lead) .& (next .== prefix.second)
            }
            // A byte is a continuation exactly where one of the three before it is a lead that
            // needs one there; then the lead's own range limits apply to the byte after it.
            let continuation = (bytes .>= x80) .& (bytes .< xC0)
            let demanded = (previous1 .>= xC0) .| (previous2 .>= xE0) .| (previous3 .>= xF0)
            var malformed = continuation .^ demanded
            malformed .|= ((bytes .>= xC0) .& (bytes .< xC2)) .| (bytes .>= xF5)
            malformed .|= ((previous1 .== xE0) .& (bytes .< xA0)) .| ((previous1 .== xED) .& (bytes .>= xA0))
            malformed .|= ((previous1 .== xF0) .& (bytes .< x90)) .| ((previous1 .== xF4) .& (bytes .>= x90))
            // One unit per scalar, two for a four-byte one.
            let blockUnits = Self.ones(.!continuation) &+ Self.ones(bytes .>= xF0)

            if any(stops .| malformed) {
                guard any(stops) else { return nil }
                let stopLane = splat(16).replacing(with: Self.lanes, where: stops).min()
                // The stop byte itself is checked too: a lead before it may still demand a continuation.
                guard !any(malformed .& (Self.lanes .<= splat(stopLane))) else { return nil }
                pendingUnits &+= blockUnits.replacing(with: 0, where: Self.lanes .>= splat(stopLane))
                return (block + Int(stopLane), units + Int(pendingUnits.wrappedSum()))
            }
            pendingUnits &+= blockUnits
            pendingBlocks += 1
            if pendingBlocks == 7 {
                units += Int(pendingUnits.wrappedSum())
                pendingUnits = Bytes()
                pendingBlocks = 0
            }
            block += 16
        }
        units += Int(pendingUnits.wrappedSum())
        guard block > start else { return (start, 0) }
        // The last scalar may continue past the final block: leave it to the per-scalar path.
        var lead = block - 1
        while text[lead] & 0xC0 == 0x80 { lead -= 1 }
        units -= text[lead] >= 0xF0 ? 2 : 1
        return (lead, units)
    }

    private typealias Bytes = SIMD16<UInt8>

    private static let lanes = Bytes(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)

    @inline(__always)
    private static func ones(_ mask: SIMDMask<SIMD16<Int8>>) -> Bytes {
        Bytes(repeating: 0).replacing(with: 1, where: mask)
    }

    // MARK: - ASCII

    private static func matchASCII(
        in text: UnsafeBufferPointer<UInt8>,
        needle: [UInt8],
        failure: [Int],
        wholeCharacters: Bool
    ) -> Outcome {
        var matched = 0
        var position = 0
        var lastNonASCIIUnit = -2
        var lastNonASCIIByte: Int?
        var pendingHit: Int?

        // Only a plain starter is known not to share a character with an ASCII neighbour. `byte` is
        // where the scalar starts, or nil for a unit of a special lowercase.
        func isPlainStarter(at byte: Int?) -> Bool {
            guard let byte, let (scalar, _) = decode(text, at: byte) else { return false }
            return Self.isPlainStarter(scalar)
        }

        // Advances over one ASCII unit of the lowercased text; non-nil once decided.
        func advance(ascii unit: UInt8) -> Outcome? {
            if let pendingHit { return .hit(utf16Offset: pendingHit) }
            while matched > 0 && needle[matched] != unit { matched = failure[matched - 1] }
            if needle[matched] == unit { matched += 1 }
            position += 1
            guard matched == needle.count else { return nil }
            let start = position - needle.count
            if !wholeCharacters { return .hit(utf16Offset: start) }
            if lastNonASCIIUnit == start - 1 && !isPlainStarter(at: lastNonASCIIByte) { return .undecided }
            pendingHit = start
            return nil
        }

        func advance(nonASCIIUnits count: Int, at byte: Int?) -> Outcome? {
            if let pendingHit { return isPlainStarter(at: byte) ? .hit(utf16Offset: pendingHit) : .undecided }
            matched = 0
            position += count
            lastNonASCIIUnit = position - 1
            lastNonASCIIByte = byte
            return nil
        }

        let table = LowercaseTable.shared
        let first = needle[0]
        var index = 0
        while index < text.count {
            // Nothing pending: no unit before the next possible first unit can change the outcome.
            if matched == 0 && pendingHit == nil {
                guard let (end, units) = skipPlainText(in: text, from: index, stop: first, table: table) else {
                    return .undecided
                }
                if end > index {
                    position += units
                    if text[end - 1] >= 128 {
                        var lead = end - 1
                        while text[lead] & 0xC0 == 0x80 { lead -= 1 }
                        lastNonASCIIUnit = position - 1
                        lastNonASCIIByte = lead
                    }
                    index = end
                }
            }
            let byte = text[index]
            if byte < 128 {
                let unit = byte >= 65 && byte <= 90 ? byte | 0x20 : byte
                // Nothing pending, and this unit cannot start a match.
                if matched == 0 && pendingHit == nil && unit != first {
                    position += 1
                    index += 1
                    continue
                }
                if let outcome = advance(ascii: unit) { return outcome }
                index += 1
                continue
            }
            guard let width = validatedWidth(in: text, at: index) else { return .undecided }
            if let lowercase = table.special(in: text, at: index, width: width) {
                for unit in lowercase {
                    let outcome = unit < 128 ? advance(ascii: UInt8(unit)) : advance(nonASCIIUnits: 1, at: nil)
                    if let outcome { return outcome }
                }
            } else if let outcome = advance(nonASCIIUnits: width == 4 ? 2 : 1, at: index) {
                return outcome
            }
            index += width
        }
        if let pendingHit { return .hit(utf16Offset: pendingHit) }
        return .miss
    }

    private static func failureTable(_ needle: [UInt8]) -> [Int] {
        var failure = Array(repeating: 0, count: needle.count)
        var length = 0
        for index in needle.indices.dropFirst() {
            while length > 0 && needle[index] != needle[length] { length = failure[length - 1] }
            if needle[index] == needle[length] { length += 1 }
            failure[index] = length
        }
        return failure
    }

    // MARK: - Plain starters

    /// Scalars that are composed (NFC-stable, combining class 0), lowercase to such a scalar of the
    /// same UTF-16 length, and never share a character with a neighbour. Verified against every
    /// assigned scalar in these ranges; a scalar the runtime does not know behaves the same in String.
    fileprivate static func isPlainStarter(_ value: UInt32) -> Bool {
        switch value {
        case 0...0x7F, 0xA0...0xAC, 0xAE...0x12F, 0x131...0x17F, 0x370...0x373, 0x375...0x37D, 0x37F...0x386,
             0x388...0x482, 0x48A...0x52F, 0x2010...0x2027, 0x2030...0x205E, 0x2190...0x2328, 0x232B...0x23FF,
             0x2500...0x27BF, 0x2B00...0x2BFF, 0x3000...0x3029, 0x3030...0x303F, 0x3041...0x3096, 0x309B...0x30FF,
             0x3100...0x9FFF, 0xAC00...0xD7A3, 0xFF01...0xFF60, 0x1F000...0x1F1E5, 0x1F200...0x1F3FA,
             0x1F400...0x1FAFF, 0x20000...0x2F7FF, 0x30000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    // MARK: - UTF-8

    /// The earliest start of any pattern that begins before `limit`.
    private static func firstIndex(
        ofAny patterns: [[UInt8]],
        in text: UnsafeBufferPointer<UInt8>,
        before limit: Int? = nil
    ) -> Int? {
        var best: Int?
        for pattern in patterns {
            if let start = firstIndex(of: pattern, in: text, before: best ?? limit ?? text.count) { best = start }
        }
        return best
    }

    /// Anchored on the pattern's last byte, a continuation byte for a multi-byte scalar: rare in
    /// any script, unlike lead bytes, so `memchr` skips most of the text.
    private static func firstIndex(of pattern: [UInt8], in text: UnsafeBufferPointer<UInt8>, before limit: Int) -> Int? {
        guard let base = text.baseAddress, !pattern.isEmpty, pattern.count <= text.count else { return nil }
        let raw = UnsafeRawPointer(base)
        let anchor = pattern.count - 1
        let lastStart = min(limit - 1, text.count - pattern.count)
        var start = 0
        while start <= lastStart {
            guard let found = memchr(raw + start + anchor, Int32(pattern[anchor]), text.count - start - anchor) else {
                return nil
            }
            let candidate = raw.distance(to: UnsafeRawPointer(found)) - anchor
            guard candidate <= lastStart else { return nil }
            if matches(pattern, in: text, at: candidate) { return candidate }
            start = candidate + 1
        }
        return nil
    }

    private static func matches(_ pattern: [UInt8], in text: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        index + pattern.count <= text.count && pattern.indices.allSatisfy { text[index + $0] == pattern[$0] }
    }

    private static func lastScalar(of text: UnsafeBufferPointer<UInt8>) -> UInt32? {
        var start = text.count - 1
        while start > 0 && text[start] & 0xC0 == 0x80 && text.count - start < 4 { start -= 1 }
        guard let (scalar, width) = decode(text, at: start), start + width == text.count else { return nil }
        return scalar
    }

    private static func decode(_ text: UnsafeBufferPointer<UInt8>, at index: Int) -> (UInt32, Int)? {
        let lead = text[index]
        if lead < 128 { return (UInt32(lead), 1) }
        guard let width = validatedWidth(in: text, at: index) else { return nil }
        var value = UInt32(lead) & (width == 2 ? 0x1F : width == 3 ? 0x0F : 0x07)
        for offset in 1..<width {
            value = value << 6 | UInt32(text[index + offset] & 0x3F)
        }
        return (value, width)
    }

    /// The width of the well-formed non-ASCII scalar at `index`, or nil (String decodes it as U+FFFD).
    private static func validatedWidth(in text: UnsafeBufferPointer<UInt8>, at index: Int) -> Int? {
        let lead = text[index]
        let width: Int
        switch lead {
        case 0xC2...0xDF: width = 2
        case 0xE0...0xEF: width = 3
        case 0xF0...0xF4: width = 4
        default: return nil
        }
        guard index + width <= text.count else { return nil }
        for offset in 1..<width where text[index + offset] & 0xC0 != 0x80 {
            return nil
        }
        let next = text[index + 1]
        guard !(lead == 0xE0 && next < 0xA0), !(lead == 0xED && next >= 0xA0),
              !(lead == 0xF0 && next < 0x90), !(lead == 0xF4 && next >= 0x90) else { return nil }
        return width
    }
}

/// Every scalar outside the plain-starter ranges whose lowercase, fully decomposed, is not just itself.
/// Built once, for the first needle matched as whole characters (about 20 ms).
private enum ExpansionTable {
    private static let expansions: [(scalar: UInt32, expansion: [UInt32])] = {
        var table: [(scalar: UInt32, expansion: [UInt32])] = []
        for value in UInt32(0x80)...0x2FFFF where !LoweredTextMatcher.isPlainStarter(value) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let lowercase = scalar.properties.changesWhenLowercased ? scalar.properties.lowercaseMapping : String(scalar)
            let expansion = lowercase.decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
            if expansion != [value] { table.append((value, expansion)) }
        }
        return table
    }()

    /// The scalars that, lowercased and decomposed, consist only of `scalars`.
    static func scalars(madeOf scalars: Set<UInt32>) -> [UInt32] {
        expansions.filter { $0.expansion.allSatisfy(scalars.contains) }.map(\.scalar)
    }
}

/// Lowercase mappings that matter to byte-level matching, from one scan of planes 0 and 1, which
/// hold every scalar that changes when lowercased.
private struct LowercaseTable: Sendable {
    /// By lead byte: scalars whose lowercase has an ASCII unit or another UTF-16 length (İ, Kelvin sign).
    private let specialByLeadByte: [[(source: [UInt8], lowercase: [UInt16])]]
    private let hasSpecialLead: [Bool]
    /// The first two bytes of every special scalar, repeated across a vector; a skip stops there.
    let specialPrefixes: [(lead: SIMD16<UInt8>, second: SIMD16<UInt8>)]
    /// A scalar's other spellings: every scalar whose whole lowercase it is (д ← Д).
    let sources: [UInt32: [Unicode.Scalar]]
    /// Scalars produced only as part of a longer lowercase (the "i" and dot of İ).
    let partOfLongerLowercase: Set<UInt32>

    static let shared = LowercaseTable()

    private init() {
        var special = Array(repeating: [(source: [UInt8], lowercase: [UInt16])](), count: 256)
        var sources: [UInt32: [Unicode.Scalar]] = [:]
        var partOfLongerLowercase = Set<UInt32>()
        for value in UInt32(128)...0x1FFFF {
            guard let scalar = Unicode.Scalar(value), scalar.properties.changesWhenLowercased else { continue }
            let lowercase = scalar.properties.lowercaseMapping
            let units = Array(lowercase.utf16)
            if units.contains(where: { $0 < 128 }) || units.count != String(scalar).utf16.count {
                let bytes = Array(String(scalar).utf8)
                special[Int(bytes[0])].append((bytes, units))
            }
            let scalars = Array(lowercase.unicodeScalars)
            if scalars.count == 1 {
                sources[scalars[0].value, default: []].append(scalar)
            } else {
                partOfLongerLowercase.formUnion(scalars.map(\.value))
            }
        }
        specialByLeadByte = special
        hasSpecialLead = special.map { !$0.isEmpty }
        var prefixes: [(lead: UInt8, second: UInt8)] = []
        for entry in special.joined() where !prefixes.contains(where: { $0 == (entry.source[0], entry.source[1]) }) {
            prefixes.append((entry.source[0], entry.source[1]))
        }
        specialPrefixes = prefixes.map { (SIMD16(repeating: $0.lead), SIMD16(repeating: $0.second)) }
        self.sources = sources
        self.partOfLongerLowercase = partOfLongerLowercase
    }

    func special(in text: UnsafeBufferPointer<UInt8>, at index: Int, width: Int) -> [UInt16]? {
        let lead = Int(text[index])
        // Checked first: reading an entry list retains it, and almost no lead byte has one.
        guard hasSpecialLead[lead] else { return nil }
        return specialByLeadByte[lead].first { entry in
            entry.source.count == width && entry.source.indices.allSatisfy { text[index + $0] == entry.source[$0] }
        }?.lowercase
    }
}
