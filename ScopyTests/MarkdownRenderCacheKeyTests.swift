import XCTest

final class MarkdownRenderCacheKeyTests: XCTestCase {
    func testCacheKeyIncludesRendererProfilePolicyAndNamespace() {
        let profile: MarkdownSourceProfile = .chatGPTMarkdown
        let context = MarkdownRenderContext(
            renderer: .legacyMarkdownIt,
            profile: profile,
            policy: MarkdownRepairPolicy.legacyCompatible(for: profile),
            policyVersion: "policy-x",
            cacheNamespace: "namespace-y"
        )

        let key = MarkdownRenderCacheKey.make(contentHash: "hash-z", context: context)

        XCTAssertEqual(key, "md|legacyMarkdownIt|namespace-y|chatGPTMarkdown|policy-x|hash-z")
    }

    func testEmptyContentHashReturnsEmptyKey() {
        let context = MarkdownRenderContextResolver.defaultContext(for: "# Title")

        XCTAssertEqual(MarkdownRenderCacheKey.make(contentHash: "", context: context), "")
    }
}
