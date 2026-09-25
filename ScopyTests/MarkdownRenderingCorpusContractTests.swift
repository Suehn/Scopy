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

            let document = MarkdownHTMLDocumentBuilder.document(source: "Text", context: context)
            XCTAssertEqual(try embeddedPolicy(in: document), testCase.payload, testCase.name)
        }
    }

    /// The exact bytes of the `policy` object in the document's render input (`{"policy":{…},"source":…}`).
    private func embeddedPolicy(in document: String) throws -> String {
        let open = #"<script type="application/json" id="scopy-render-input">{"policy":"#
        let start = try XCTUnwrap(document.range(of: open)).upperBound
        var depth = 0
        var inString = false
        var escaped = false
        for index in document[start...].indices {
            let character = document[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(document[start...index]) }
            }
        }
        XCTFail("unterminated policy object")
        return ""
    }
}
