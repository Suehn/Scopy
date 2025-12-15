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
        XCTAssertTrue(protected.placeholders[0].original.contains("\\tag{2-1}"))

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("katex.min.js"))
        XCTAssertTrue(html.contains("\\begin{equation}"))
        XCTAssertTrue(html.contains("\\tag{2-1}"))
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

    func testLaTeXSubsectionAndEquationEnvironmentArePassedThroughToRenderer() {
        let input = """
        \\subsection{2.1 问题定义与符号约定}

        设用户集合为 ($\\mathcal{U}$)，物品集合为 ($\\mathcal{I}$)。

        \\begin{equation}
        \\begin{aligned}
        \\mathcal{E}\\subseteq \\mathcal{U}\\times\\mathcal{I}.
        \\end{aligned}
        \\tag{2-1}
        \\end{equation}
        """

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("katex.min.js"))
        XCTAssertTrue(html.contains("## 2.1 问题定义与符号约定"))
        XCTAssertTrue(html.contains("\\begin{equation}"))
        XCTAssertTrue(html.contains("\\tag{2-1}"))
    }

    func testFullPaperSnippetDoesNotInjectNestedDollarsInsideEquationEnvironments() {
        let input = """
        \\subsection{2.1 问题定义与符号约定}

        设用户集合为 ($\\mathcal{U}$)，物品集合为 ($\\mathcal{I}$)，观测到的交互集合为
        \\begin{equation}
        \\begin{aligned}
        \\mathcal{E}\\subseteq \\mathcal{U}\\times\\mathcal{I}.
        \\end{aligned}
        \\tag{2-1}
        \\end{equation}

        为了刻画用户—物品之间的协同关系，常将交互数据表示为二部图
        \\begin{equation}
        \\begin{aligned}
        \\mathcal{G}=(\\mathcal{V},\\mathcal{E}),\\quad \\mathcal{V}=\\mathcal{U}\\cup\\mathcal{I}.
        \\end{aligned}
        \\tag{2-2}
        \\end{equation}
        """

        let latexNormalized = LaTeXDocumentNormalizer.normalize(input)
        let normalized = MathNormalizer.wrapLooseLaTeX(latexNormalized)
        let protected = MathProtector.protectMath(in: normalized)

        let equationBlocks = protected.placeholders
            .map(\.original)
            .filter { $0.contains("\\begin{equation}") && $0.contains("\\end{equation}") }
        XCTAssertFalse(equationBlocks.isEmpty)

        for block in equationBlocks {
            // Environment math should not contain nested `$...$` injected by the loose-LaTeX wrapper.
            XCTAssertFalse(block.contains("$"))
            XCTAssertTrue(block.contains("\\mathcal"))
            XCTAssertTrue(block.contains("\\tag{"))
        }
    }

    func testLooseLeftRightRunIsWrappedAsSingleMathSegment() {
        let input = """
        where \\hat{s}_i^\\mu=\\hat{S}_i^\\mu / s, \\mathbf{r}_i is the $d$-dimensional vector, \
        J\\left(\\left|\\mathbf{r}_i-\\mathbf{r}_j\\right|\\right) is the interaction strength.
        """

        let normalized = MathNormalizer.wrapLooseLaTeX(input)
        XCTAssertTrue(normalized.contains("$J\\left("))
        XCTAssertTrue(normalized.contains("\\right)$"))

        let protected = MathProtector.protectMath(in: normalized)
        let leftRight = protected.placeholders.map(\.original).first { s in
            s.contains("$J\\left(") && s.contains("\\right)$")
        }
        XCTAssertNotNil(leftRight)
        if let leftRight {
            XCTAssertFalse(leftRight.dropFirst().contains("$$"))
            XCTAssertTrue(leftRight.contains("\\mathbf{r}_i"))
        }
    }

    func testWassersteinSnippetWrapsLooseParenMathAndKeepsEquationEnvironmentIntact() {
        let input = """
        \\subsubsection{2.6.1 最优传输与 Wasserstein 距离}

        最优传输（Optimal Transport, OT）关注将一个分布“搬运”为另一个分布的最小代价。设 $(P)$ 与 $(Q)$ 为定义在空间 $(\\Omega)$ 上的概率分布，$(\\Pi(P,Q))$ 表示以 $(P,Q)$ 为边缘分布的联合分布集合。

        Wasserstein距离可定义为
        \\begin{equation}
        \\begin{aligned}
        W(P,Q)
        =
        \\inf_{\\pi\\in\\Pi(P,Q)} \\int_{\\Omega\\times\\Omega} c(x,y), d\\pi(x,y).
        \\end{aligned}
        \\tag{2-17}
        \\end{equation}
        """

        let latexNormalized = LaTeXDocumentNormalizer.normalize(input)
        let normalized = MathNormalizer.wrapLooseLaTeX(latexNormalized)

        // Keep already-delimited `$...$` paren math intact.
        XCTAssertTrue(normalized.contains("$(\\Pi(P,Q))$"))
        XCTAssertTrue(normalized.contains("$(\\Omega)$"))

        let protected = MathProtector.protectMath(in: normalized)
        let equationBlocks = protected.placeholders
            .map(\.original)
            .filter { $0.contains("\\begin{equation}") && $0.contains("\\end{equation}") }
        XCTAssertEqual(equationBlocks.count, 1)
        if let block = equationBlocks.first {
            XCTAssertFalse(block.contains("$"))
            XCTAssertTrue(block.contains("\\inf_{\\pi\\in\\Pi(P,Q)}"))
            XCTAssertTrue(block.contains("\\Omega\\times\\Omega"))
            XCTAssertTrue(block.contains("\\tag{2-17}"))
        }
    }
}
