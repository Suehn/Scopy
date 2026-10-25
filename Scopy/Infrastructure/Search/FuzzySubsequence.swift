import Foundation

/// A fuzzy term of three or more characters, matched as a subsequence of a lowercased text over
/// the elements `FuzzyMatcher` compares: UTF-16 units for an ASCII term, characters otherwise.
///
/// Score: with the leftmost greedy match spanning elements `first...last`, `10m - span - gaps`,
/// that is `10m - (last - first) - (last - (m - 1))`; or `10m - (m - 1) - p` when the first
/// contiguous occurrence, starting at element `p`, scores higher. Greedy ends at the earliest
/// element any match can end at, so that occurrence ends at or after `last`, and it scores higher
/// exactly when `p < 2 * last - first - 2 * (m - 1)`; the scan for it stops there.
struct FuzzySubsequence: Sendable {
    private enum Pattern: Sendable {
        /// An ASCII UTF-16 unit is exactly an ASCII byte of the UTF-8.
        case ascii([UInt8])
        case characters(CharacterPattern)
    }

    private struct CharacterPattern: Sendable {
        let characters: [Character]
        /// Per character, the plain starter that equals it as a whole character, or `noScalar`.
        let scalars: [UInt32]
        /// KMP failure links over `characters`.
        let failure: [Int]
    }

    private static let noScalar = UInt32.max

    private let pattern: Pattern

    init(termLower: String) {
        if termLower.utf8.allSatisfy({ $0 < 0x80 }) {
            pattern = .ascii(Array(termLower.utf8))
            return
        }
        let characters = Array(termLower)
        let scalars = characters.map { character -> UInt32 in
            let composed = String(character).precomposedStringWithCanonicalMapping.unicodeScalars
            guard composed.count == 1, let scalar = composed.first,
                  UTF8Text.isPlainStarter(scalar.value),
                  Character(scalar) == character else { return Self.noScalar }
            return scalar.value
        }
        pattern = .characters(
            CharacterPattern(characters: characters, scalars: scalars, failure: Self.failureLinks(characters))
        )
    }

    /// KMP failure links: for each prefix, the length of its longest proper prefix that is also
    /// its suffix.
    static func failureLinks<Element: Equatable>(_ pattern: [Element]) -> [Int] {
        var failure = Array(repeating: 0, count: pattern.count)
        var length = 0
        for index in pattern.indices.dropFirst() {
            while length > 0 && pattern[index] != pattern[length] { length = failure[length - 1] }
            if pattern[index] == pattern[length] { length += 1 }
            failure[index] = length
        }
        return failure
    }

    func score(textLower: String) -> Int? {
        var contiguous = textLower
        contiguous.makeContiguousUTF8()
        let text = contiguous
        let score = text.utf8.withContiguousStorageIfAvailable { bytes -> Int? in
            switch pattern {
            case .ascii(let units):
                return Self.scoreASCII(units, in: bytes)
            case .characters(let characters):
                return Self.scoreCharacters(characters, in: bytes, text: text)
            }
        }
        return score ?? nil
    }

    // MARK: - Score model

    private static func greedyScore(count: Int, first: Int, last: Int) -> Int {
        10 * count - (last - first) - (last - (count - 1))
    }

    private static func contiguousScore(count: Int, start: Int) -> Int {
        10 * count - (count - 1) - start
    }

    /// Contiguous occurrences that start before this element outscore the greedy match.
    private static func contiguousBound(count: Int, first: Int, last: Int) -> Int {
        2 * last - first - 2 * (count - 1)
    }

    // MARK: - UTF-16 units

    /// Greedy jumps between bytes with `memchr`; positions come from counting UTF-16 units only up
    /// to the first and last match.
    private static func scoreASCII(_ units: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        let raw = UnsafeRawPointer(base)
        let count = units.count
        var from = 0
        var firstByte = 0
        for (index, unit) in units.enumerated() {
            guard from < bytes.count, let found = memchr(raw + from, Int32(unit), bytes.count - from) else {
                return nil
            }
            let byte = raw.distance(to: UnsafeRawPointer(found))
            if index == 0 { firstByte = byte }
            from = byte + 1
        }
        let lastByte = from - 1
        let first = UTF8Text.utf16Count(bytes, from: 0, to: firstByte)
        let last = first + UTF8Text.utf16Count(bytes, from: firstByte, to: lastByte)
        let greedy = greedyScore(count: count, first: first, last: last)
        let bound = contiguousBound(count: count, first: first, last: last)

        // An occurrence ends at or after `lastByte`, so one starting before it is ASCII up to there.
        var candidate = lastByte
        while candidate > 0, lastByte - candidate < count - 1, bytes[candidate - 1] < 0x80 {
            candidate -= 1
        }
        var candidateUnits = last - (lastByte - candidate)
        let firstUnit = Int32(units[0])
        while candidate + count <= bytes.count {
            guard let found = memchr(raw + candidate, firstUnit, bytes.count - count + 1 - candidate) else { break }
            let byte = raw.distance(to: UnsafeRawPointer(found))
            candidateUnits += UTF8Text.utf16Count(bytes, from: candidate, to: byte)
            guard candidateUnits < bound else { break }
            if memcmp(raw + byte, units, count) == 0 {
                return contiguousScore(count: count, start: candidateUnits)
            }
            candidate = byte + 1
            candidateUnits += 1
        }
        return greedy
    }

    // MARK: - Characters

    private static func scoreCharacters(
        _ pattern: CharacterPattern,
        in bytes: UnsafeBufferPointer<UInt8>,
        text: String
    ) -> Int? {
        let count = pattern.characters.count
        var cursor = UTF8Text.CharacterCursor(bytes: bytes, text: text, offset: 0)
        var matched = 0
        var position = 0
        var first = 0
        while !cursor.isAtEnd {
            if equals(cursor, pattern: pattern, at: matched) {
                if matched == 0 { first = position }
                matched += 1
                if matched == count { break }
            }
            cursor.advance()
            position += 1
        }
        guard matched == count else { return nil }
        let last = position
        let greedy = greedyScore(count: count, first: first, last: last)
        let bound = contiguousBound(count: count, first: first, last: last)
        position = last - (count - 1)
        guard position < bound else { return greedy }

        var offset = cursor.offset
        for _ in 1..<count {
            offset = cursor.characterStart(before: offset)
        }
        cursor = UTF8Text.CharacterCursor(bytes: bytes, text: text, offset: offset)
        matched = 0
        while !cursor.isAtEnd, position - matched < bound {
            while matched > 0, !equals(cursor, pattern: pattern, at: matched) {
                matched = pattern.failure[matched - 1]
            }
            if equals(cursor, pattern: pattern, at: matched) {
                matched += 1
                if matched == count {
                    return contiguousScore(count: count, start: position - (count - 1))
                }
            }
            cursor.advance()
            position += 1
        }
        return greedy
    }

    private static func equals(_ cursor: UTF8Text.CharacterCursor, pattern: CharacterPattern, at index: Int) -> Bool {
        guard let scalar = cursor.plainScalar else { return cursor.character == pattern.characters[index] }
        let key = pattern.scalars[index]
        if key != noScalar { return key == scalar }
        return cursor.character == pattern.characters[index]
    }
}
