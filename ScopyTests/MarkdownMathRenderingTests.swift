import XCTest
import Down

final class MarkdownMathRenderingTests: XCTestCase {
    func testInlineDollarMathIsNotBrokenByMarkdownEmphasis() {
        let input = """
        使用用户集合为 ($\\mathcal{U}_u^{+}$), 物品集合为 ($\\mathcal{I}$)。
        """

        let html = MarkdownHTMLRenderer.render(markdown: input)

        XCTAssertTrue(html.contains("katex.min.js"))
        XCTAssertTrue(html.contains("$\\mathcal{U}_u^{+}$"))
        XCTAssertTrue(html.contains("$\\mathcal{I}$"))
        XCTAssertFalse(html.contains("<em>u</em>"))
    }

    func testAlignEnvironmentSurvivesMarkdownParsing() {
        let input = """
        下面是一个公式块：
        \\begin{align} a_b &= c_d \\\\ e_f &= g_h \\end{align}
        """

        let html = MarkdownHTMLRenderer.render(markdown: input)

        XCTAssertTrue(html.contains("\\begin{align}"))
        XCTAssertTrue(html.contains("\\end{align}"))
        XCTAssertTrue(html.contains("a_b"))
    }

    func testPdfExtractedAdjacentInlineMathIsDisambiguated() {
        let input = "$\\mathbf{a} &\\in \\Delta^{n},\\quad $\\mathbf{b}$$\\in$ $\\Delta^{m}$$,"

        if ProcessInfo.processInfo.environment["SCOPY_TEST_DEBUG_MATH"] == "1" {
            let normalized = MathNormalizer.wrapLooseLaTeX(input)
            let protected = MathProtector.protectMath(in: normalized)
            print("DEBUG normalized:", normalized)
            print("DEBUG protected markdown:", protected.markdown)
            print("DEBUG placeholders:", protected.placeholders)
        }

        let html = MarkdownHTMLRenderer.render(markdown: input)

        // `&` inside inline math often indicates missing aligned environment in extraction; upgrade it.
        XCTAssertTrue(html.contains("$$\\begin{aligned}"))
        XCTAssertTrue(html.contains("\\end{aligned}$$"))
        XCTAssertTrue(html.contains("\\mathbf{b}"))

        // Adjacent `$...$` segments should not form `$$` and break parsing.
        XCTAssertTrue(html.contains("$\\in$"))

        // Trailing `$$,` artifact should collapse to a single `$` before punctuation.
        XCTAssertTrue(html.contains("$\\Delta^{m}$,"))
    }

    func testMultilineDisplayMathDollarBlocksAreProtected() {
        let input = """
        这里是公式：
        $$
        \\phi \\triangleq \\frac{\\bar T_{\\text{aug}}}{\\bar T_{\\text{io}}}
        $$
        结束。
        """

        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        let protected = MathProtector.protectMath(in: normalized)

        XCTAssertEqual(protected.placeholders.count, 1)
        XCTAssertTrue(protected.placeholders[0].original.contains("\\phi"))
        XCTAssertTrue(protected.markdown.contains(protected.placeholders[0].placeholder))

        let rendered = try? Down(markdownString: protected.markdown).toHTML(DownOptions.safe.union(.smart))
        XCTAssertNotNil(rendered)

        if let rendered {
            XCTAssertTrue(rendered.contains(protected.placeholders[0].placeholder))
            let restored = MathProtector.restoreMath(in: rendered, placeholders: protected.placeholders, escape: { $0 })
            XCTAssertTrue(restored.contains("\\phi"))
            XCTAssertTrue(restored.contains("\\triangleq"))
            XCTAssertTrue(restored.contains("\\frac"))
            XCTAssertTrue(restored.contains("\\bar"))
            XCTAssertTrue(restored.contains("\\text{aug}"))
            XCTAssertTrue(restored.contains("\\text{io}"))
        }

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("katex.min.js"))
        XCTAssertTrue(html.contains("$$"))
        XCTAssertTrue(html.contains("\\phi"))
    }

    func testDoubleBackslashTeXCommandsInsideMathAreNormalized() {
        let input = """
        这个公式来自转义字符串：$\\\\mathcal{U}_u^{+}$。
        """

        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        let protected = MathProtector.protectMath(in: normalized)

        XCTAssertEqual(protected.placeholders.count, 1)
        XCTAssertTrue(protected.placeholders[0].original.contains("$\\mathcal{U}_u^{+}$"))
        XCTAssertFalse(protected.placeholders[0].original.contains("$\\\\mathcal{U}_u^{+}$"))

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("$\\mathcal{U}_u^{+}$"))
    }

    func testBracketedDisplayMathBlocksAreNormalizedToDollarBlocks() {
        let input = """
        下面是一个 display block：
        [
        \\mathcal{L}=\\sum_{(u,i,j)}\\log\\sigma(\\hat y_{ui}-\\hat y_{uj})
        ]
        """

        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        XCTAssertTrue(normalized.contains("\n$$\n"))
        XCTAssertFalse(normalized.contains("\n[\n"))
        XCTAssertFalse(normalized.contains("\n]\n"))

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("$$"))
        XCTAssertTrue(html.contains("\\mathcal"))
    }

    func testFullWidthParenthesesMathIsWrapped() {
        let input = "设用户集合为（\\mathcal{U}），物品集合为（\\mathcal{I}）。"
        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        XCTAssertTrue(normalized.contains("$\\left(\\mathcal{U}\\right)$"))
        XCTAssertTrue(normalized.contains("$\\left(\\mathcal{I}\\right)$"))
    }

    func testTableParenMathGetsWrapped() {
        let input = """
        | 符号 | 含义 |
        | --- | --- |
        | (\\mathcal{U},\\mathcal{I}) | 用户集合、物品集合 |
        | (\\mathbf{e}_u,\\mathbf{e}_i) | 用户/物品潜在表示 |
        """

        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        XCTAssertTrue(normalized.contains("$\\left(\\mathcal{U},\\mathcal{I}\\right)$"))
        XCTAssertTrue(normalized.contains("$\\left(\\mathbf{e}_u,\\mathbf{e}_i\\right)$"))
    }

    func testSetNotationBracesAreNormalized() {
        let input = "(\\mathcal{N}_u={i\\mid (u,i)\\in\\mathcal{E}})"
        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        let protected = MathProtector.protectMath(in: normalized)
        XCTAssertEqual(protected.placeholders.count, 1)
        XCTAssertTrue(protected.placeholders[0].original.contains("\\{i\\mid (u,i)\\in\\mathcal{E}\\}"))
    }

    func testMultilineEquationEnvironmentBlocksAreProtected() {
        let input = """
        这里是一个公式块：
        \\begin{equation}
        \\begin{aligned}
        \\mathcal{E}\\subseteq \\mathcal{U}\\times\\mathcal{I}.
        \\end{aligned}
        \\tag{2-1}
        \\end{equation}
        """

        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        let protected = MathProtector.protectMath(in: normalized)

        XCTAssertEqual(protected.placeholders.count, 1)
        XCTAssertTrue(protected.placeholders[0].original.contains("\\begin{equation}"))
        XCTAssertTrue(protected.placeholders[0].original.contains("\\end{equation}"))

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("katex.min.js"))
        XCTAssertTrue(html.contains("\\begin{equation}"))
        XCTAssertTrue(html.contains("\\end{equation}"))
    }

    func testEquationEnvironmentTriggersMathPipelineEvenWithoutDollars() {
        let input = """
        只包含环境公式：
        \\begin{equation}
        x = 1
        \\end{equation}
        """

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("katex.min.js"))
    }
}
