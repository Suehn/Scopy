import AppKit
import SwiftUI
import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class SearchMatchPresentationTests: XCTestCase {
    func testMixedSourcesExposeCountLabelsAndBothFragments() {
        let text = SearchMatchPresentation.attributedText(
            context: SearchMatchContext(
                mode: .exact,
                fragments: [
                    fragment(source: .content, text: "body needle", offset: 5, length: 6),
                    fragment(source: .note, text: "note needle", offset: 5, length: 6)
                ],
                occurrenceCount: 2,
                occurrenceCountIsTruncated: false,
                isPositionOnly: false
            ),
            itemType: .text,
            metadataPrefix: "10字 · 1行"
        )

        XCTAssertEqual(
            String(text.characters),
            "2 matches · Content · body needle  /  Note · note needle"
        )
        XCTAssertEqual(highlightedRunCount(in: text), 2)
        XCTAssertTrue(highlightedRuns(in: text).allSatisfy { $0[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] == .black })

        XCTAssertEqual(
            SearchMatchPresentation.accessibilityDescription(
                context: SearchMatchContext(
                    mode: .exact,
                    fragments: [
                        fragment(source: .content, text: "body needle", offset: 5, length: 6),
                        fragment(source: .note, text: "note needle", offset: 5, length: 6)
                    ],
                    occurrenceCount: 2,
                    occurrenceCountIsTruncated: false,
                    isPositionOnly: false
                ),
                itemType: .text
            ),
            "Exact search. 2 matches found. Fragment 1, Content: body needle; matches: needle."
                + " Fragment 2, Note: note needle; matches: needle."
        )
    }

    func testAccessibilityDescriptionDistinguishesDistantSameSourceFragments() {
        let description = SearchMatchPresentation.accessibilityDescription(
            context: SearchMatchContext(
                mode: .fuzzyPlus,
                fragments: [
                    fragment(source: .content, text: "first alpha context", offset: 6, length: 5),
                    fragment(source: .content, text: "second beta context", offset: 7, length: 4)
                ],
                occurrenceCount: 2,
                occurrenceCountIsTruncated: false,
                isPositionOnly: false
            ),
            itemType: .text
        )

        XCTAssertEqual(
            description,
            "Fuzzy+ search. 2 matches found. Fragment 1, Content: first alpha context; matches: alpha."
                + " Fragment 2, Content: second beta context; matches: beta."
        )
    }

    func testAccessibilityDescriptionKeepsFullContextAndBoundsHighlightedTerms() {
        let description = SearchMatchPresentation.accessibilityDescription(
            context: SearchMatchContext(
                mode: .exact,
                fragments: [
                    SearchMatchFragment(
                        source: .note,
                        text: "a b c d e complete note context",
                        highlightedRanges: [
                            SearchMatchTextRange(offset: 0, length: 1),
                            SearchMatchTextRange(offset: 2, length: 1),
                            SearchMatchTextRange(offset: 4, length: 1),
                            SearchMatchTextRange(offset: 6, length: 1),
                            SearchMatchTextRange(offset: 8, length: 1)
                        ]
                    )
                ],
                occurrenceCount: 5,
                occurrenceCountIsTruncated: false,
                isPositionOnly: false
            ),
            itemType: .text
        )

        let visibleTerms = ListFormatter.localizedString(byJoining: ["a", "b", "c", "d"])
        XCTAssertEqual(
            description,
            "Exact search. 5 matches found. Note: a b c d e complete note context; matches: \(visibleTerms) and more."
        )
    }

    func testSingleBodyFragmentKeepsCompactMetadataPrefix() {
        let text = SearchMatchPresentation.attributedText(
            context: SearchMatchContext(
                mode: .exact,
                fragments: [fragment(source: .content, text: "tail needle", offset: 5, length: 6)],
                occurrenceCount: 1,
                occurrenceCountIsTruncated: false,
                isPositionOnly: false
            ),
            itemType: .text,
            metadataPrefix: "100字 · 8行"
        )

        XCTAssertEqual(String(text.characters), "100字 · 8行 · tail needle")
        XCTAssertEqual(highlightedRunCount(in: text), 1)
    }

    func testFileAndPositionOnlyEvidenceUseExplicitLabels() {
        let text = SearchMatchPresentation.attributedText(
            context: SearchMatchContext(
                mode: .regex,
                fragments: [SearchMatchFragment(source: .content, text: "…archive.txt", highlightedRanges: [])],
                occurrenceCount: 3,
                occurrenceCountIsTruncated: true,
                isPositionOnly: true
            ),
            itemType: .file,
            metadataPrefix: nil
        )

        XCTAssertEqual(String(text.characters), "3+ matches · Position match · Path · …archive.txt")
        XCTAssertEqual(highlightedRunCount(in: text), 0)
    }

    func testImageAndNoteEvidenceUseExplicitSourceLabels() {
        let text = SearchMatchPresentation.attributedText(
            context: SearchMatchContext(
                mode: .exact,
                fragments: [
                    fragment(source: .content, text: "image clue", offset: 6, length: 4),
                    fragment(source: .note, text: "note clue", offset: 5, length: 4)
                ],
                occurrenceCount: 2,
                occurrenceCountIsTruncated: false,
                isPositionOnly: false
            ),
            itemType: .image,
            metadataPrefix: nil
        )

        XCTAssertEqual(String(text.characters), "2 matches · Image · image clue  /  Note · note clue")
    }

    func testBlankFragmentShowsPlaceholder() {
        let context = SearchMatchContext(
            mode: .regex,
            fragments: [SearchMatchFragment(source: .content, text: "", highlightedRanges: [])],
            occurrenceCount: 1,
            occurrenceCountIsTruncated: false,
            isPositionOnly: true
        )

        let text = SearchMatchPresentation.attributedText(context: context, itemType: .text, metadataPrefix: nil)
        XCTAssertEqual(String(text.characters), "Position match · (Blank content)")
        XCTAssertEqual(
            SearchMatchPresentation.accessibilityDescription(context: context, itemType: .text),
            "Regex search. 1 matches found. Position match. Content: (Blank content)."
        )
    }

    func testHistoryItemHarnessRendersSearchEvidenceOffscreen() throws {
        let environment = ProcessInfo.processInfo.environment
        let overrides = [
            "SCOPY_UITEST_HISTORY_ITEM_SCENARIO": "long-markdown-text",
            "SCOPY_UITEST_HISTORY_ITEM_KEYBOARD_SELECTED": "1",
            "SCOPY_UITEST_HISTORY_ITEM_SEARCH_QUERY": "指数",
            "SCOPY_UITEST_HISTORY_ITEM_SEARCH_MODE": "exact",
            "SCOPY_UITEST_HISTORY_ITEM_COMPACT_WIDTH": "1"
        ]
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        defer {
            for key in overrides.keys {
                if let original = environment[key] {
                    setenv(key, original, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let hostingView = NSHostingView(rootView: HistoryItemHarnessView())
            hostingView.appearance = NSAppearance(named: appearanceName)
            hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()

            let bitmap = try XCTUnwrap(
                hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            )
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000)

            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "search-evidence-\(appearanceName.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func fragment(
        source: SearchMatchSource,
        text: String,
        offset: Int,
        length: Int
    ) -> SearchMatchFragment {
        SearchMatchFragment(
            source: source,
            text: text,
            highlightedRanges: [SearchMatchTextRange(offset: offset, length: length)]
        )
    }

    private func highlightedRunCount(in text: AttributedString) -> Int {
        highlightedRuns(in: text).count
    }

    private func highlightedRuns(in text: AttributedString) -> [AttributedString.Runs.Run] {
        text.runs.filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }
    }
}
