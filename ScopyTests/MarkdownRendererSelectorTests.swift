import XCTest

final class MarkdownRendererSelectorTests: XCTestCase {
    func testDefaultFlagsKeepAllProfilesOnLegacy() {
        for profile in allProfiles {
            XCTAssertEqual(
                MarkdownRendererSelector.rendererKind(for: profile, flags: .disabled),
                .legacyMarkdownIt,
                "profile: \(profile)"
            )
        }
    }

    func testSafeProfileFlagOnlyCutsOverAuthoredAndChatGPTMarkdown() {
        let flags = MarkdownRendererFlagSet(
            forceLegacy: false,
            forceUnified: false,
            unifiedSafeProfilesEnabled: true,
            unifiedScientificEnabled: false,
            shadowUnifiedEnabled: false
        )

        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .authoredMarkdown, flags: flags), .unified)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .chatGPTMarkdown, flags: flags), .unified)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .scientificMarkdown, flags: flags), .legacyMarkdownIt)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .latexDocumentLike, flags: flags), .legacyMarkdownIt)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .pdfOCRScientific, flags: flags), .legacyMarkdownIt)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .richHTML, flags: flags), .legacyMarkdownIt)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .plainTextUnknown, flags: flags), .legacyMarkdownIt)
    }

    func testForceFlagsOverrideProfileSelection() {
        let forceUnified = MarkdownRendererFlagSet(
            forceLegacy: false,
            forceUnified: true,
            unifiedSafeProfilesEnabled: false,
            unifiedScientificEnabled: false,
            shadowUnifiedEnabled: false
        )
        let forceLegacy = MarkdownRendererFlagSet(
            forceLegacy: true,
            forceUnified: true,
            unifiedSafeProfilesEnabled: true,
            unifiedScientificEnabled: true,
            shadowUnifiedEnabled: true
        )

        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .pdfOCRScientific, flags: forceUnified), .unified)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .authoredMarkdown, flags: forceLegacy), .legacyMarkdownIt)
    }

    private var allProfiles: [MarkdownSourceProfile] {
        [
            .authoredMarkdown,
            .chatGPTMarkdown,
            .scientificMarkdown,
            .latexDocumentLike,
            .pdfOCRScientific,
            .richHTML,
            .plainTextUnknown
        ]
    }
}
