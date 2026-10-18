import XCTest
@testable import ScopyKit

/// Locks `FuzzySubsequence` to its definition, the better of the leftmost greedy match and the
/// first contiguous occurrence over UTF-16 units or characters of the lowercased text, and checks
/// the plain-starter facts its scalar comparison relies on.
final class FuzzySubsequenceTests: XCTestCase {
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

    /// Scalars that read through the String: combining marks, CR LF, Hangul jamo, emoji
    /// sequences, regional indicators, Indic clusters, a prepended mark, canonical singletons
    /// (U+F900 is 豈, U+212B is Å), decomposed and composed forms, and uppercase that lowercases
    /// to more than one scalar.
    private static let pieces: [String] = [
        "a", "b", "c", "e", "=", " ", "原", "文", "错", "豈", "\u{F900}", "Å", "\u{212B}", "A\u{30A}",
        "é", "e\u{301}", "\u{301}", "\u{323}", "\u{2260}", "\u{338}", "\r", "\n", "\r\n", "가", "\u{1100}",
        "\u{1161}", "\u{11A8}", "😀", "\u{1F3FD}", "\u{200D}", "\u{FE0F}", "\u{1F1E8}", "\u{1F1F3}",
        "\u{915}", "\u{94D}", "\u{600}", "\u{903}", "\u{130}", "Σ", "ß", "\u{80}", "\u{10000}",
    ]

    func testScoreMatchesItsDefinitionExhaustively() {
        // Two CJK plain starters; two ASCII letters; ASCII terms among non-ASCII scalars of two,
        // three and four UTF-8 bytes, the last taking two UTF-16 units.
        let cases: [(alphabet: [String], termAlphabet: [String], maxLength: Int)] = [
            (["原", "文"], ["原", "文"], 10),
            (["a", "b"], ["a", "b"], 10),
            (["a", "b", "é", "数", "😀"], ["a", "b"], 5),
        ]
        var mismatches: [String] = []
        var comparisons = 0
        for (alphabet, termAlphabet, maxLength) in cases {
            let texts = (1...maxLength).flatMap { Self.strings(over: alphabet, length: $0) }
            let characters = texts.map { Array($0) }
            let units = texts.map { Array($0.utf16) }
            for term in [3, 4].flatMap({ Self.strings(over: termAlphabet, length: $0) }) {
                let subsequence = FuzzySubsequence(termLower: term)
                let isASCII = term.canBeConverted(to: .ascii)
                for (index, text) in texts.enumerated() {
                    comparisons += 1
                    let got = subsequence.score(textLower: text)
                    let want = isASCII
                        ? Self.definitionScore(units[index], Array(term.utf16))
                        : Self.definitionScore(characters[index], Array(term))
                    if got != want, mismatches.count < 20 {
                        mismatches.append("\(term) in \(text): got \(String(describing: got)) want \(String(describing: want))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(comparisons, 150_000)
        XCTAssertEqual(mismatches, [])
    }

    func testScoreMatchesItsDefinitionOnTextsThatReadThroughTheString() {
        var rng = SplitMix64(state: 1)
        var mismatches: [String] = []
        var contiguousWins = 0
        var characterTerms = 0
        for _ in 0..<20_000 {
            let text = (0..<Int.random(in: 0...24, using: &rng))
                .map { _ in Self.pieces.randomElement(using: &rng)! }
                .joined()
                .lowercased()
            let term = Self.term(from: text, using: &rng)
            guard term.count >= 3 else { continue }
            let got = FuzzySubsequence(termLower: term).score(textLower: text)
            let want = Self.definitionScore(textLower: text, termLower: term)
            if got != want, mismatches.count < 20 {
                mismatches.append("\(term.unicodeScalars.map(\.value)) in \(text.unicodeScalars.map(\.value))")
            }
            if let want, want != Self.greedyScore(textLower: text, termLower: term) { contiguousWins += 1 }
            if !term.canBeConverted(to: .ascii) { characterTerms += 1 }
        }
        XCTAssertEqual(mismatches, [])
        XCTAssertGreaterThan(contiguousWins, 300)
        XCTAssertGreaterThan(characterTerms, 5_000)
    }

    func testScoresTheFirstContiguousOccurrenceWhenItBeatsGreedy() {
        // Greedy takes the earlier 原文: 50 - 11 - 20 = 19; the occurrence at 20 scores 26.
        XCTAssertEqual(
            FuzzySubsequence(termLower: "原文错了嘛").score(textLower: "也就是你最开始回答的推导和原文有冲突？是原文错了嘛"),
            26
        )
        // An occurrence that ends after greedy: a0 b2 b4 scores 24, "abb" at 3 scores 25.
        XCTAssertEqual(FuzzySubsequence(termLower: "abb").score(textLower: "aababb"), 25)
        // One at the bound only ties: a0 b1 c5 and "abc" at 6 both score 22.
        XCTAssertEqual(FuzzySubsequence(termLower: "abc").score(textLower: "abxxxcabc"), 22)
        // Past it, greedy stands: a0 b2 c4 scores 24, "abc" at 6 would score 22.
        XCTAssertEqual(FuzzySubsequence(termLower: "abc").score(textLower: "a_b_c_abc"), 24)
        // UTF-16 units: 😀 is two.
        XCTAssertEqual(FuzzySubsequence(termLower: "abc").score(textLower: "ab😀abc"), 24)
        XCTAssertNil(FuzzySubsequence(termLower: "abc").score(textLower: "acb"))
    }

    /// The scalar comparison relies on two facts about plain starters: each is NFC-stable, so two
    /// of them are canonically equivalent only when they are the same scalar, and any two of them
    /// other than CR LF have a grapheme break between them, so one between two others is a whole
    /// character. A scalar with any joining break property would join one of the probes: "a"
    /// after (Extend, ZWJ, SpacingMark), "가" before (Prepend, L) or after (V, T), "각" after (T),
    /// itself (regional indicator, jamo), and LF after CR.
    func testPlainStartersAreNFCStableAndBreakFromEachOther() {
        var failures: [UInt32] = []
        var checked = 0
        for value in UInt32(0)...0x3FFFF where LoweredTextMatcher.isPlainStarter(value) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            checked += 1
            let single = String(scalar)
            let probe = "a" + single + "가" + single + "각" + single + single + (value == 0x0D ? "" : "\n" + single) + "\r"
            if single.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value) != [value]
                || probe.count != probe.unicodeScalars.count {
                failures.append(value)
            }
        }
        XCTAssertGreaterThan(checked, 150_000)
        XCTAssertEqual(failures, [])
        XCTAssertEqual("\r\n".count, 1, "CR LF is the one pair that joins")
    }

    // MARK: - Definition

    /// The score by definition, on arrays of the compared elements.
    private static func definitionScore(textLower: String, termLower: String) -> Int? {
        if termLower.canBeConverted(to: .ascii) {
            return definitionScore(Array(textLower.utf16), Array(termLower.utf16))
        }
        return definitionScore(Array(textLower), Array(termLower))
    }

    private static func greedyScore(textLower: String, termLower: String) -> Int? {
        if termLower.canBeConverted(to: .ascii) {
            return greedyScore(Array(textLower.utf16), Array(termLower.utf16))
        }
        return greedyScore(Array(textLower), Array(termLower))
    }

    private static func definitionScore<Element: Equatable>(_ text: [Element], _ term: [Element]) -> Int? {
        guard let greedy = greedyScore(text, term) else { return nil }
        let count = term.count
        guard let start = (0...(text.count - count)).first(where: { Array(text[$0..<($0 + count)]) == term }) else {
            return greedy
        }
        return max(greedy, 10 * count - (count - 1) - start)
    }

    private static func greedyScore<Element: Equatable>(_ text: [Element], _ term: [Element]) -> Int? {
        var positions: [Int] = []
        for (position, element) in text.enumerated() where positions.count < term.count && element == term[positions.count] {
            positions.append(position)
        }
        guard positions.count == term.count, let first = positions.first, let last = positions.last else { return nil }
        let span = last - first
        let gaps = last - (term.count - 1)
        return 10 * term.count - span - gaps
    }

    // MARK: - Generation

    private static func strings(over alphabet: [String], length: Int) -> [String] {
        guard length > 0 else { return [""] }
        return strings(over: alphabet, length: length - 1).flatMap { prefix in alphabet.map { prefix + $0 } }
    }

    /// Characters taken in order from the text, sometimes contiguous, sometimes replaced by a
    /// random piece, so most terms match and some contiguously.
    private static func term(from text: String, using rng: inout SplitMix64) -> String {
        let characters = Array(text)
        let count = Int.random(in: 3...5, using: &rng)
        guard characters.count >= count else {
            return (0..<count).map { _ in pieces.randomElement(using: &rng)! }.joined().lowercased()
        }
        var picked: [Character]
        if Bool.random(using: &rng) {
            let start = Int.random(in: 0...(characters.count - count), using: &rng)
            picked = Array(characters[start..<(start + count)])
        } else {
            picked = Array(characters.indices.shuffled(using: &rng).prefix(count).sorted().map { characters[$0] })
        }
        if Int.random(in: 0..<4, using: &rng) == 0 {
            picked[Int.random(in: 0..<count, using: &rng)] = Character(pieces.randomElement(using: &rng)!.lowercased())
        }
        return String(picked).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
