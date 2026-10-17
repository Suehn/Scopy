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
        var units = 0
        var index = 0
        while index < text.count {
            if text[index] < 128 {
                units += 1
                index += 1
                continue
            }
            guard let width = validatedWidth(in: text, at: index) else { return nil }
            units += LowercaseTable.shared.special(in: text, at: index, width: width)?.count ?? (width == 4 ? 2 : 1)
            index += width
        }
        return units
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
