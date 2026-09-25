import ScopyKit
import XCTest

/// Cross-language renderer input contract. Node reads the same files: `corpus.test.js` renders the
/// corpus with the policy declared in `cases.json`, and `policy-contract.test.js` consumes the
/// payloads pinned here.
final class MarkdownRenderingCorpusContractTests: XCTestCase {
    private struct CorpusCase: Decodable {
        let name: String
        let file: String
        let expectedProfile: String
        let policy: DeclaredPolicy
    }

    private struct DeclaredPolicy: Decodable {
        let allowLatexDocumentNormalize: Bool
        let allowLatexInlineTextNormalize: Bool
        let allowLooseMathRepair: Bool
    }

    private struct PolicyContract: Decodable {
        let cases: [PolicyCase]
    }

    private struct PolicyCase: Decodable {
        let name: String
        let profile: String
        let linkEnrichment: [String: LinkEnrichmentEntry]?
        let payload: String
    }

    func testCorpusProfileAndRepairPolicyMatchDeclarations() throws {
        let cases = try JSONDecoder().decode([CorpusCase].self, from: TestFixture.data("MarkdownRenderingCorpus/cases.json"))
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for testCase in cases {
            let source = try String(contentsOf: TestFixture.url("MarkdownRenderingCorpus/\(testCase.file)"), encoding: .utf8)
            let context = MarkdownRenderContextResolver.defaultContext(for: source)

            XCTAssertEqual(context.profile.rawValue, testCase.expectedProfile, testCase.name)
            XCTAssertEqual(context.policy.allowLatexDocumentNormalize, testCase.policy.allowLatexDocumentNormalize, testCase.name)
            XCTAssertEqual(context.policy.allowLatexInlineTextNormalize, testCase.policy.allowLatexInlineTextNormalize, testCase.name)
            XCTAssertEqual(context.policy.allowLooseMathRepair, testCase.policy.allowLooseMathRepair, testCase.name)
        }
    }

    func testPolicyPayloadMatchesSharedContractFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/MarkdownRenderer/test/fixtures/policy-contract.json")
        let contract = try JSONDecoder().decode(PolicyContract.self, from: Data(contentsOf: fixture))
        XCTAssertGreaterThanOrEqual(contract.cases.count, 5)
        for testCase in contract.cases {
            let profile = try XCTUnwrap(MarkdownSourceProfile(rawValue: testCase.profile), testCase.name)
            var context = MarkdownRenderContext(
                profile: profile,
                policy: .conservativeDefault(for: profile),
                layoutScale: MarkdownRenderLayoutConstants.defaultChatGPTLayoutScale
            )
            context.linkEnrichment = testCase.linkEnrichment.map {
                LinkEnrichmentPayload(version: LinkEnrichmentPayload.formatVersion, fetchedAt: Date(timeIntervalSince1970: 0), entries: $0)
            }

            XCTAssertEqual(MarkdownHTMLDocumentBuilder.policyPayloadJSON(context: context), testCase.payload, testCase.name)
        }
    }
}
