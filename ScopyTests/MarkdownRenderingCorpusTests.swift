import XCTest

final class MarkdownRenderingCorpusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UnifiedMarkdownRenderer.setBundleAvailabilityOverride { true }
    }

    override func tearDown() {
        UnifiedMarkdownRenderer.setBundleAvailabilityOverride(nil)
        super.tearDown()
    }

    func testCorpusProfilesPoliciesAndDefaultRendererShells() throws {
        for testCase in try loadCases() {
            let source = try loadSource(file: testCase.file)

            let profile = MarkdownSourceProfileDetector.detect(source)
            let context = MarkdownRenderContextResolver.defaultContext(for: source)
            let output = MarkdownHTMLRenderer.render(markdown: source, context: context)
            let normalized = MathNormalizer.wrapLooseLaTeX(source)

            XCTAssertEqual(profile.rawValue, testCase.expectedProfile, testCase.name)
            XCTAssertEqual(context.renderer.rawValue, testCase.expectedDefaultRenderer, testCase.name)
            XCTAssertEqual(context.policy.allowLooseMathRepair, testCase.allowLooseMathRepair, testCase.name)
            XCTAssertFalse(output.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, testCase.name)
            XCTAssertFalse(normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, testCase.name)

            switch context.renderer {
            case .unified:
                XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"), testCase.name)
                XCTAssertFalse(output.html.contains("markdown-it.min.js"), testCase.name)
            case .legacyMarkdownIt:
                XCTAssertTrue(output.html.contains("markdown-it.min.js"), testCase.name)
            }
        }
    }

    private func loadCases() throws -> [CorpusCase] {
        let data = try TestFixture.data("MarkdownRenderingCorpus/cases.json")
        return try JSONDecoder().decode([CorpusCase].self, from: data)
    }

    private func loadSource(file: String) throws -> String {
        let data = try TestFixture.data("MarkdownRenderingCorpus/\(file)")
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CorpusCase: Decodable {
    let name: String
    let file: String
    let expectedProfile: String
    let expectedDefaultRenderer: String
    let allowLooseMathRepair: Bool
}
