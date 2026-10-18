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

    func testUnicode61TokenRangeCountsSurrogatePairsBeforeTheToken() throws {
        let text = String(repeating: "😀 数据，", count: 3_000) + "\r\nneedle。"
        let context = try XCTUnwrap(makeContext(query: "needle", mode: .exact, text: text))

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["needle"])
    }

    func testLiteralEvidenceRangesSurviveMultiByteScalarsBeforeTheMatch() throws {
        let text = String(repeating: "é😀 ", count: 400) + "前文数据后文"
        let context = try XCTUnwrap(makeContext(query: "数据", mode: .exact, text: text))

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["数据"])
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

    func testShortExactUsesRealNoteOnlyEvidence() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: "ab",
                mode: .exact,
                text: "unrelated body",
                note: "ab exists only in the note"
            )
        )

        XCTAssertEqual(context.fragments.map(\.source), [.note])
        XCTAssertEqual(highlightedText(context.fragments[0]), ["ab"])
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

    func testFuzzyEvidenceHighlightsTheContiguousOccurrenceThatOutscoresGreedy() throws {
        let cjk = try XCTUnwrap(
            makeContext(
                query: "原文错了嘛",
                mode: .fuzzyPlus,
                text: "也就是你最开始回答的推导和原文有冲突？是原文错了嘛"
            )
        )
        XCTAssertEqual(cjk.fragments.flatMap(highlightedText), ["原文错了嘛"])

        let ascii = try XCTUnwrap(makeContext(query: "abc", mode: .fuzzy, text: "ab_abc"))
        XCTAssertEqual(ascii.fragments.flatMap(highlightedText), ["abc"])
    }

    func testFuzzyEvidenceHighlightsAContiguousOccurrenceAfterTheGreedyMatch() throws {
        // Greedy a0 b2 b4 scores 24; "abb" at 3, ending after it, scores 25.
        let ascii = try XCTUnwrap(makeContext(query: "abb", mode: .fuzzy, text: "aababb"))
        XCTAssertEqual(ascii.fragments.flatMap(\.highlightedRanges), [SearchMatchTextRange(offset: 3, length: 3)])

        // Greedy 0, 4, 6 scores 20; 数学题 at 7, before the bound 2 * 6 - 0 - 4 = 8, scores 21.
        let cjk = try XCTUnwrap(makeContext(query: "数学题", mode: .fuzzyPlus, text: "数xxx学y题数学题"))
        XCTAssertEqual(cjk.fragments.flatMap(\.highlightedRanges), [SearchMatchTextRange(offset: 7, length: 3)])

        // At the bound the scores tie and greedy stands: 0, 1, 5 and "abc" at 6 both score 22.
        let tie = try XCTUnwrap(makeContext(query: "abc", mode: .fuzzy, text: "abxxxcabc"))
        XCTAssertEqual(tie.fragments.flatMap(highlightedText), ["ab", "c"])
    }

    func testFuzzyEvidenceFollowsAnOccurrenceAcrossTheNoteSeparator() throws {
        // `a_b_ab\ncd`: greedy 0...8 scores 38, "ab\ncd" at 4 scores 42.
        let context = try XCTUnwrap(makeContext(query: "ab\ncd", mode: .fuzzy, text: "a_b_ab", note: "cd"))
        XCTAssertEqual(context.fragments.map(\.source), [.content, .note])
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["ab", "cd"])
    }

    func testASCIIFuzzyEvidenceMatchesInsideADecomposedCharacterLikeTheScore() throws {
        let context = try XCTUnwrap(
            makeContext(query: "cafe", mode: .fuzzy, text: "/Users/example/Cafe\u{301}.txt")
        )

        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["Cafe\u{301}"])
    }

    /// Every text of up to nine characters over two letters, against every three- and
    /// four-character query, on the character path (CJK) and the UTF-16 path (ASCII): evidence
    /// highlights the greedy match, or the first contiguous occurrence when it scores higher.
    func testFuzzyEvidenceMatchesItsDefinitionExhaustively() throws {
        for alphabet in [Array("原文"), Array("ab")] {
            func strings(length: Int) -> [[Character]] {
                guard length > 0 else { return [[]] }
                return strings(length: length - 1).flatMap { prefix in alphabet.map { prefix + [$0] } }
            }
            let texts = (1...9).flatMap(strings(length:))
            for query in [3, 4].flatMap(strings(length:)) {
                let matcher = try SearchMatchContextBuilder.prepare(
                    request: SearchRequest(query: String(query), mode: .fuzzy),
                    coverage: .complete
                )
                for text in texts {
                    let context = try matcher.makeContext(plainText: String(text), note: nil)
                    XCTAssertEqual(
                        context?.fragments.flatMap(\.highlightedRanges),
                        expectedHighlights(text: text, query: query),
                        "\(String(query)) in \(String(text))"
                    )
                }
            }
        }
    }

    func testFuzzyEvidenceFindsTheContiguousOccurrenceInTheNote() throws {
        let context = try XCTUnwrap(
            makeContext(query: "数学题", mode: .fuzzyPlus, text: "数", note: "x数学题")
        )

        XCTAssertEqual(context.fragments.map(\.source), [.note])
        XCTAssertEqual(context.fragments.flatMap(highlightedText), ["数学题"])
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

    func testRegexUsesRealNoteOnlyEvidence() throws {
        let context = try XCTUnwrap(
            makeContext(
                query: #"R-\d+"#,
                mode: .regex,
                text: "unrelated body",
                note: "ticket R-42 is saved here"
            )
        )

        XCTAssertEqual(context.fragments.map(\.source), [.note])
        XCTAssertEqual(highlightedText(context.fragments[0]), ["R-42"])
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
        XCTAssertEqual(context.fragments.map(\.text), [""])
    }

    func testWhitespaceRegexProducesVisiblePositionEvidence() throws {
        let context = try XCTUnwrap(makeContext(query: #"\s+"#, mode: .regex, text: " \n\t "))

        XCTAssertEqual(context.occurrenceCount, 1)
        XCTAssertTrue(context.isPositionOnly)
        XCTAssertEqual(context.fragments.map(\.text), [""])
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

    /// The greedy match, or the first contiguous occurrence when it scores higher: when it starts
    /// before `2 * last - first - 2 * (m - 1)`.
    private func expectedHighlights(text: [Character], query: [Character]) -> [SearchMatchTextRange]? {
        var positions: [Int] = []
        for (position, character) in text.enumerated()
        where positions.count < query.count && character == query[positions.count] {
            positions.append(position)
        }
        guard let first = positions.first, let last = positions.last, positions.count == query.count else { return nil }
        let count = query.count
        if let start = (0...(text.count - count)).first(where: { Array(text[$0..<($0 + count)]) == query }),
           start < 2 * last - first - 2 * (count - 1) {
            positions = Array(start..<(start + count))
        }
        var ranges: [SearchMatchTextRange] = []
        for position in positions {
            if let previous = ranges.last, previous.offset + previous.length == position {
                ranges[ranges.count - 1] = SearchMatchTextRange(offset: previous.offset, length: previous.length + 1)
            } else {
                ranges.append(SearchMatchTextRange(offset: position, length: 1))
            }
        }
        return ranges
    }

    private func highlightedText(_ fragment: SearchMatchFragment) -> [String] {
        let characters = Array(fragment.text)
        return fragment.highlightedRanges.map { range in
            String(characters[range.offset..<(range.offset + range.length)])
        }
    }
}
