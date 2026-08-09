import XCTest
import ScopyKit

final class SearchMatchContextBuilderTests: XCTestCase {
    func testExactMatchShowsMultipleOccurrencesAndTwoDistantFragments() throws {
        let text = "needle" + String(repeating: " x", count: 45)
            + " needle " + String(repeating: "y ", count: 45) + "needle"

        let context = try XCTUnwrap(makeContext(query: "needle", mode: .exact, text: text))

        XCTAssertEqual(context.occurrenceCount, 3)
        XCTAssertFalse(context.occurrenceCountIsTruncated)
        XCTAssertEqual(context.fragments.count, 2)
        XCTAssertTrue(context.fragments.allSatisfy { !$0.highlightedRanges.isEmpty })
        XCTAssertTrue(context.fragments.flatMap(highlightedText).allSatisfy {
            $0.caseInsensitiveCompare("needle") == .orderedSame
        })
    }

    func testExactFTSEvidenceDoesNotHighlightTokenSeparator() throws {
        let context = try XCTUnwrap(
            makeContext(query: "Agents.md", mode: .exact, text: "prefix AGENTS.md suffix")
        )

        XCTAssertEqual(context.fragments.count, 1)
        XCTAssertEqual(highlightedText(context.fragments[0]), ["AGENTS", "md"])
    }

    func testExactMatchCountsCaseVariantsWithoutChangingOriginalText() throws {
        let context = try XCTUnwrap(
            makeContext(query: "alpha", mode: .exact, text: "Alpha alpha ALPHA")
        )

        XCTAssertEqual(context.occurrenceCount, 3)
        XCTAssertEqual(highlightedText(context.fragments[0]), ["Alpha", "alpha", "ALPHA"])
    }

    func testShortExactMatchKeepsCJKCharacterBoundaries() throws {
        let context = try XCTUnwrap(
            makeContext(query: "搜索", mode: .exact, text: "前文搜索结果后文")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]), ["搜索"])
    }

    func testExactFTSEvidenceUsesUnicodeTokenizerBoundaries() throws {
        let context = try XCTUnwrap(
            makeContext(query: "foo_bar", mode: .exact, text: "prefix foo bar suffix")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]), ["foo", "bar"])
    }

    func testExactFTSEvidenceLeavesDifferentPunctuationBetweenTokensUnhighlighted() throws {
        let context = try XCTUnwrap(
            makeContext(query: "foo_bar", mode: .exact, text: "prefix foo.bar suffix")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]), ["foo", "bar"])
    }

    func testUnicode61DoesNotFoldFullwidthTokenIntoASCIIEvidence() throws {
        let context = try XCTUnwrap(
            makeContext(query: "ABC", mode: .exact, text: "ＡＢＣ marker ABC")
        )

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["ABC"])
    }

    func testUnicode61DoesNotRemoveGreekDiacriticFromEvidence() throws {
        let context = try XCTUnwrap(
            makeContext(query: "αλφα", mode: .exact, text: "άλφα marker αλφα")
        )

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["αλφα"])
    }

    func testUnicode61TokenRangeSurvivesTokenizerChunkBoundary() throws {
        let text = String(repeating: " ", count: 8_190) + "needle"
        let context = try XCTUnwrap(makeContext(query: "needle", mode: .exact, text: text))

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["needle"])
    }

    func testExactFTSEvidenceDoesNotMarkSubstringInsideLargerToken() throws {
        let context = try XCTUnwrap(
            makeContext(query: "foo", mode: .exact, text: "foobar comes first; standalone foo follows")
        )

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["foo"])
    }

    func testExactFTSEvidenceUsesRealNoteHitInsteadOfFalseContentSubstring() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "foo",
                mode: .exact,
                text: "foobar is not an FTS token match",
                note: "standalone foo is the indexed match"
            )
        )

        XCTAssertEqual(context.fragments.map(\.source), [.note])
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["foo"])
    }

    func testExactFTSStyleTokensExplainContentAndNoteMatch() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "alpha beta",
                mode: .exact,
                text: "alpha appears in the body",
                note: "the note explains beta"
            )
        )

        XCTAssertEqual(context.fragments.map(\.source), [.content, .note])
        XCTAssertEqual(Set(context.fragments.flatMap(highlightedText).map { $0.lowercased() }), ["alpha", "beta"])
    }

    func testNoteOnlyMatchUsesNoteSource() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "needle",
                mode: .exact,
                text: "unrelated body",
                note: "saved because the needle is explained here"
            )
        )

        XCTAssertEqual(context.fragments.map(\.source), [.note])
        XCTAssertEqual(highlightedText(context.fragments[0]), ["needle"])
    }

    func testExactEvidenceKeepsNoteSourceAfterBodyOccurrenceCap() throws {
        let body = Array(repeating: "needle", count: 40).joined(separator: " ")
        let context = try XCTUnwrap(
            makeContext(query: "needle", mode: .exact, text: body, note: "note needle")
        )

        XCTAssertEqual(context.fragments.map(\.source), [.content, .note])
        XCTAssertEqual(context.occurrenceCount, 33)
        XCTAssertTrue(context.occurrenceCountIsTruncated)
        XCTAssertEqual(highlightedText(context.fragments[1]), ["needle"])
    }

    func testShortExactDoesNotInventNoteEvidence() throws {
        XCTAssertNil(
            try makeContext(
                query: "ab",
                mode: .exact,
                text: "unrelated body",
                note: "ab exists only in the note"
            )
        )
    }

    func testFuzzyMatchHighlightsGreedySubsequenceWitness() throws {
        let context = try XCTUnwrap(
            makeContext(query: "cmd", mode: .fuzzy, text: "create my document")
        )

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(highlightedText(context.fragments[0]).map { $0.lowercased() }, ["c", "m", "d"])
    }

    func testFuzzyEvidenceUsesEarliestGreedyWitnessInsteadOfLaterLiteral() throws {
        let context = try XCTUnwrap(
            makeContext(query: "cmd", mode: .fuzzy, text: "create my document, then cmd")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]).map { $0.lowercased() }, ["c", "m", "d"])
    }

    func testShortFuzzyEvidenceUsesContiguousBackendSemantics() throws {
        let context = try XCTUnwrap(
            makeContext(query: "ab", mode: .fuzzy, text: "a then b, followed by ab")
        )

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(highlightedText(context.fragments[0]).map { $0.lowercased() }, ["ab"])
    }

    func testFuzzyPlusCanExplainTokensAcrossContentAndNote() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "command 搜",
                mode: .fuzzyPlus,
                text: "run this command now",
                note: "搜索线索"
            )
        )

        XCTAssertEqual(context.fragments.map(\.source), [.content, .note])
        XCTAssertEqual(Set(context.fragments.flatMap(highlightedText).map { $0.lowercased() }), ["command", "搜"])
    }

    func testFuzzyPlusRequiresEveryTermForCompleteCoverage() throws {
        XCTAssertNil(
            try makeContext(
                query: "command missing",
                mode: .fuzzyPlus,
                text: "run this command now"
            )
        )
    }

    func testStagedFuzzyPrefilterExplainsOutOfOrderTokens() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "alpha beta",
                mode: .fuzzy,
                text: "beta comes before alpha",
                coverage: .stagedRefine
            )
        )

        XCTAssertEqual(Set(context.fragments.flatMap(highlightedText).map { $0.lowercased() }), ["alpha", "beta"])
    }

    func testRegexCountsAllVisibleMatches() throws {
        let context = try XCTUnwrap(
            makeContext(query: #"foo\d"#, mode: .regex, text: "foo1 then foo2")
        )

        XCTAssertEqual(context.occurrenceCount, 2)
        XCTAssertEqual(highlightedText(context.fragments[0]), ["foo1", "foo2"])
    }

    func testZeroWidthRegexProducesPositionEvidence() throws {
        let context = try XCTUnwrap(
            makeContext(query: #"(?=foo)"#, mode: .regex, text: "foo and foo")
        )

        XCTAssertEqual(context.occurrenceCount, 2)
        XCTAssertTrue(context.isPositionOnly)
        XCTAssertTrue(context.fragments.allSatisfy { $0.highlightedRanges.isEmpty })
    }

    func testZeroWidthRegexExplainsEmptyImageContent() throws {
        let context = try XCTUnwrap(makeContext(query: "^", mode: .regex, text: ""))

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertTrue(context.isPositionOnly)
        XCTAssertEqual(context.fragments.map(\.text), ["（空内容）"])
    }

    func testWhitespaceRegexProducesVisiblePositionEvidence() throws {
        let context = try XCTUnwrap(makeContext(query: #"\s+"#, mode: .regex, text: " \n\t "))

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertTrue(context.isPositionOnly)
        XCTAssertEqual(context.fragments.map(\.text), ["（空白内容）"])
    }

    func testRegexKeepsEmojiGraphemeIntact() throws {
        let emoji = "👩‍💻"
        let context = try XCTUnwrap(
            makeContext(query: emoji, mode: .regex, text: "before \(emoji) after")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]), [emoji])
    }

    func testRegexBacktrackingReportsProgressForCooperativeCancellation() throws {
        enum ExpectedCancellation: Error { case stop }

        let matcher = try SearchMatchContextBuilder.prepare(
            request: SearchRequest(query: "^x|(a+)+$", mode: .regex),
            coverage: .recentOnly(limit: 2000)
        )
        let text = "x" + String(repeating: "a", count: 28) + "!"
        let start = CFAbsoluteTimeGetCurrent()
        var checkCount = 0

        XCTAssertThrowsError(
            try matcher.makeContext(
                plainText: text,
                note: nil,
                cancellationCheck: {
                    checkCount += 1
                    if checkCount == 20 { throw ExpectedCancellation.stop }
                }
            )
        ) { error in
            XCTAssertTrue(error is ExpectedCancellation)
        }
        XCTAssertGreaterThanOrEqual(checkCount, 20)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.5)
    }

    func testInvalidRegexAndWhitespaceSemanticQueriesHaveNoEvidence() throws {
        XCTAssertThrowsError(try makeContext(query: "(", mode: .regex, text: "anything"))
        XCTAssertNil(try makeContext(query: " \n\t ", mode: .exact, text: "anything"))
        XCTAssertNil(try makeContext(query: " \n\t ", mode: .fuzzy, text: "anything"))
        XCTAssertNil(try makeContext(query: " \n\t ", mode: .fuzzyPlus, text: "anything"))
    }

    func testCanonicalDiacriticMatchHighlightsOriginalGrapheme() throws {
        let context = try XCTUnwrap(
            makeContext(query: "cafe", mode: .exact, text: "A café nearby")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]), ["café"])
    }

    func testDecomposedDiacriticMatchKeepsGraphemeIntact() throws {
        let decomposed = "cafe\u{301}"
        let context = try XCTUnwrap(
            makeContext(query: "cafe", mode: .exact, text: "A \(decomposed) nearby")
        )

        XCTAssertEqual(highlightedText(context.fragments[0]), [decomposed])
    }

    func testLongTailMatchProducesBoundedSingleLineFragment() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "needle",
                mode: .exact,
                text: String(repeating: "prefix line\n", count: 1_000) + "tail needle result"
            )
        )
        let fragment = try XCTUnwrap(context.fragments.first)

        XCTAssertLessThanOrEqual(fragment.text.count, 74)
        XCTAssertFalse(fragment.text.contains("\n"))
        XCTAssertTrue(fragment.text.hasPrefix("…"))
        XCTAssertEqual(highlightedText(fragment), ["needle"])
    }

    func testOccurrenceCountingIsBoundedAndReportedAsLowerBound() throws {
        let context = try XCTUnwrap(
            makeContext(query: "needle", mode: .exact, text: Array(repeating: "needle", count: 80).joined(separator: " "))
        )

        XCTAssertEqual(context.occurrenceCount, 32)
        XCTAssertTrue(context.occurrenceCountIsTruncated)
    }

    func testUnicode61SourceScanCooperativelyPropagatesCancellation() throws {
        enum ExpectedCancellation: Error { case stop }

        let matcher = try SearchMatchContextBuilder.prepare(
            request: SearchRequest(query: "needle", mode: .exact),
            coverage: .complete
        )
        var checkCount = 0

        XCTAssertThrowsError(
            try matcher.makeContext(
                plainText: String(repeating: "word ", count: 50_000),
                note: nil,
                cancellationCheck: {
                    checkCount += 1
                    if checkCount == 10 { throw ExpectedCancellation.stop }
                }
            )
        ) { error in
            XCTAssertTrue(error is ExpectedCancellation)
        }
        XCTAssertGreaterThanOrEqual(checkCount, 10)
    }

    private func makeContext(
        query: String,
        mode: SearchMode,
        text: String,
        note: String? = nil,
        coverage: SearchCoverage = .complete
    ) throws -> SearchMatchContext? {
        try SearchMatchContextBuilder.makeContext(
            plainText: text,
            note: note,
            request: SearchRequest(query: query, mode: mode),
            coverage: coverage
        )
    }

    private func highlightedText(_ fragment: SearchMatchFragment) -> [String] {
        let characters = Array(fragment.text)
        return fragment.highlightedRanges.map { range in
            String(characters[range.offset..<(range.offset + range.length)])
        }
    }
}
