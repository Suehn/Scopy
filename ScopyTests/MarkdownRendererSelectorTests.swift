import XCTest

final class MarkdownRendererSelectorTests: XCTestCase {
    func testDisabledFlagsKeepAllProfilesOnLegacy() {
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

    func testResolvedDefaultsCutOverSafeProfilesOnly() {
        let flags = MarkdownRendererFeatureFlags.resolve(environment: [:])

        XCTAssertFalse(flags.forceLegacy)
        XCTAssertFalse(flags.forceUnified)
        XCTAssertTrue(flags.unifiedSafeProfilesEnabled)
        XCTAssertFalse(flags.unifiedScientificEnabled)
        XCTAssertFalse(flags.shadowUnifiedEnabled)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .authoredMarkdown, flags: flags), .unified)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .chatGPTMarkdown, flags: flags), .unified)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .scientificMarkdown, flags: flags), .legacyMarkdownIt)
    }

    func testSafeProfileCutoverCanBeDisabled() {
        let flags = MarkdownRendererFeatureFlags.resolve(environment: [
            "SCOPY_MARKDOWN_UNIFIED_SAFE_PROFILES": "0"
        ])

        XCTAssertFalse(flags.unifiedSafeProfilesEnabled)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .authoredMarkdown, flags: flags), .legacyMarkdownIt)
        XCTAssertEqual(MarkdownRendererSelector.rendererKind(for: .chatGPTMarkdown, flags: flags), .legacyMarkdownIt)
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
