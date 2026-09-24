import XCTest

/// Pins the production Swift-side source preprocessing for `MarkdownRenderingCorpus`, so the
/// Node corpus test renders exactly what the app feeds the renderer bundle.
///
/// Exit condition: once every Swift-side rewrite (heading repair, table-pipe escaping, scientific
/// normalization) has moved into `Tools/MarkdownRenderer`, each `rendererInput` golden equals its
/// source file. Delete the `rendererInput` field, the golden files, and the golden assertion then;
/// keep the profile/policy contract assertions.
final class MarkdownRenderingCorpusParityTests: XCTestCase {
    private struct CorpusCase: Decodable {
        let name: String
        let file: String
        let rendererInput: String
        let expectedProfile: String
        let allowLooseMathRepair: Bool
    }

    func testSwiftPreprocessingProducesCommittedRendererInput() throws {
        let cases = try JSONDecoder().decode([CorpusCase].self, from: TestFixture.data("MarkdownRenderingCorpus/cases.json"))
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        var rewrittenCases = 0
        for testCase in cases {
            let source = try String(contentsOf: TestFixture.url("MarkdownRenderingCorpus/\(testCase.file)"), encoding: .utf8)
            let golden = try TestFixture.data("MarkdownRenderingCorpus/\(testCase.rendererInput)")
            let context = MarkdownRenderContextResolver.defaultContext(for: source)

            XCTAssertEqual(context.profile.rawValue, testCase.expectedProfile, testCase.name)
            XCTAssertEqual(context.policy.allowLooseMathRepair, testCase.allowLooseMathRepair, testCase.name)

            let output = try XCTUnwrap(MarkdownHTMLRenderer.preprocess(markdown: source, policy: context.policy))
            XCTAssertEqual(Data(output.utf8), golden, "\(testCase.name): renderer input drifted from the committed golden")
            if Data(source.utf8) != golden { rewrittenCases += 1 }
        }
        // The corpus must keep exercising the Swift-side rewrites until they move to the renderer.
        XCTAssertGreaterThanOrEqual(rewrittenCases, 2)
    }
}
