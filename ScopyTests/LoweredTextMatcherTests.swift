import XCTest
@testable import ScopyKit

/// Checks `LoweredTextMatcher` against the `String` matchers it stands in for, on seeded texts long
/// enough for its 16-byte skip: long runs, special scalars, uppercase stops, four-byte scalars,
/// combining marks and malformed bytes. Every decided outcome must equal the `String` answer.
final class LoweredTextMatcherTests: XCTestCase {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private enum Kind { case codeUnits, characters }

    private static let pieces: [[UInt8]] = [
        "a", "c", "C", "m", "M", "d", "e", "E", "i", "I", "k", "K", "o", "s", " ", "x", "1", ";", "`",
        "\r", "\n", "\r\n", "cm", "CM", "cMd", "co", "kel", "config",
        "\u{301}", "\u{308}", "\u{307}", "e\u{301}", "é", "É", "ä", "Ä",
        "\u{212A}", "\u{212B}", "\u{130}", "\u{131}", "\u{2103}", "ß", "\u{1E9E}",
        "\u{600}", "\u{200D}", "\u{FE0F}", "\u{1100}", "\u{1161}", "한", "我", "的", "数",
        "👍", "👍🏽", "🇨🇳", "\u{10000}", "\u{10FFFF}", "Д", "д", "ω", "Σ", "\u{2026}",
        String(repeating: "x", count: 300), String(repeating: "数", count: 40), String(repeating: "👍", count: 40),
    ].map { Array($0.utf8) }

    private static let malformedPieces: [[UInt8]] = [
        [0x80], [0xE4, 0xB8], [0xC0, 0x80], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80],
        [0xF0, 0x80, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFF], [0xF0, 0x9F, 0x91],
    ]

    private static let needles: [(String, Kind)] = [
        ("c", .codeUnits), ("cm", .codeUnits), ("k", .codeUnits), ("i", .codeUnits), ("\r\n", .codeUnits),
        ("我", .codeUnits), ("д", .codeUnits), ("我的", .codeUnits),
        ("cmd", .characters), ("kel", .characters), ("config", .characters), ("i", .characters),
        ("k", .characters), ("e", .characters), ("é", .characters), ("ω", .characters), ("한", .characters),
    ]

    func testDecidedOutcomesAgreeWithLowercasedStringSearch() {
        let matchers = Self.needles.map { needle, kind in
            (needle, kind, kind == .codeUnits ? LoweredTextMatcher(codeUnitsOf: needle) : LoweredTextMatcher(charactersOf: needle))
        }
        var rng = SplitMix64(state: 1)
        var mismatches: [String] = []
        var comparisons = 0
        var decided = 0
        for _ in 0..<1_500 {
            let malformed = Int.random(in: 0..<6, using: &rng) == 0
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...60, using: &rng) {
                if malformed && Int.random(in: 0..<20, using: &rng) == 0 {
                    bytes += Self.malformedPieces.randomElement(using: &rng)!
                } else {
                    bytes += Self.pieces.randomElement(using: &rng)!
                }
            }
            let text = String(decoding: bytes, as: UTF8.self)
            let lowered = text.lowercased()
            for (needle, kind, matcher) in matchers {
                guard let matcher else {
                    mismatches.append("no matcher for \(needle)")
                    continue
                }
                comparisons += 1
                let outcome = bytes.withUnsafeBufferPointer { matcher.firstMatch(in: $0) }
                let got: Int?
                switch outcome {
                case .undecided: continue
                case .hit(let offset): got = offset
                case .miss: got = nil
                }
                decided += 1
                let want = Self.reference(lowered, needle, kind)
                if got != want {
                    mismatches.append("\(needle) got \(String(describing: got)) want \(String(describing: want)) in \(bytes)")
                }
            }
            let length = bytes.withUnsafeBufferPointer { LoweredTextMatcher.loweredUTF16Length(of: $0) }
            // Decoding replaces malformed bytes, so only well-formed text survives the round trip.
            let wantLength = Array(text.utf8) == bytes ? lowered.utf16.count : nil
            if length != wantLength {
                mismatches.append("length got \(String(describing: length)) want \(String(describing: wantLength)) in \(bytes)")
            }
        }
        XCTAssertEqual(mismatches.count, 0, mismatches.prefix(3).joined(separator: "\n"))
        // Undecided texts fall back to the String matcher, so most must still be decided on bytes.
        XCTAssertGreaterThan(decided * 10, comparisons * 7)
    }

    private static func reference(_ lowered: String, _ needle: String, _ kind: Kind) -> Int? {
        switch kind {
        case .characters:
            return lowered.range(of: needle).map { $0.lowerBound.utf16Offset(in: lowered) }
        case .codeUnits:
            let haystack = Array(lowered.utf16), pattern = Array(needle.utf16)
            guard haystack.count >= pattern.count else { return nil }
            return (0...(haystack.count - pattern.count)).first {
                haystack[$0..<$0 + pattern.count].elementsEqual(pattern)
            }
        }
    }
}
