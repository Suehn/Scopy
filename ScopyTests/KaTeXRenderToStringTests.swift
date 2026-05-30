import Foundation
import JavaScriptCore
import XCTest

final class KaTeXRenderToStringTests: XCTestCase {
    func testMarkdownRendererEnablesTables() {
        let html = MarkdownHTMLRenderer.render(markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("md.enable('table')"))
        XCTAssertTrue(html.contains("markdown-it.min.js"))
    }

    func testMarkdownRendererEnablesGFMFootnotesAndTaskListRuntime() {
        let html = MarkdownHTMLRenderer.render(markdown: "- [x] done\n\nFootnote[^1]\n\n[^1]: note")
        XCTAssertTrue(html.contains("linkify: true"))
        XCTAssertTrue(html.contains("md.enable('strikethrough')"))
        XCTAssertTrue(html.contains("markdown-it-footnote.js"))
        XCTAssertTrue(html.contains("markdown-it-deflist.js"))
        XCTAssertTrue(html.contains("highlight.min.js"))
        XCTAssertTrue(html.contains("md.use(window.markdownitFootnote)"))
        XCTAssertTrue(html.contains("md.use(window.markdownitDeflist)"))
        XCTAssertTrue(html.contains("__scopyApplyTaskLists"))

        let unifiedContext = MarkdownRenderContextResolver
            .defaultContext(for: "- [x] done")
            .withRenderer(.unified)
        let unifiedHTML = MarkdownHTMLDocumentBuilder.unifiedDocument(markdown: "- [x] done", context: unifiedContext)
        XCTAssertTrue(unifiedHTML.contains("scopy-unified-renderer.iife.js"))
        XCTAssertTrue(unifiedHTML.contains("__scopyApplyTaskLists"))
        XCTAssertTrue(unifiedHTML.contains("window.__scopyApplyTaskLists(el);"))
    }

    func testMarkdownRendererHighlightsFootnoteRefsAndExposesRenderReadyState() {
        let html = MarkdownHTMLRenderer.render(markdown: "Footnote[^1]\n\n[^1]: note")
        XCTAssertTrue(html.contains(".footnote-ref a,"))
        XCTAssertTrue(html.contains("sup.footnote-ref {"))
        XCTAssertTrue(html.contains("top: auto;"))
        XCTAssertTrue(html.contains("font-size: 12px;"))
        XCTAssertTrue(html.contains("line-height: 20px;"))
        XCTAssertTrue(html.contains("vertical-align: baseline;"))
        XCTAssertTrue(html.contains("a[data-footnote-ref]"))
        XCTAssertTrue(html.contains("normalizeFootnoteReferences"))
        XCTAssertTrue(html.contains("md.renderer.rules.footnote_caption"))
        XCTAssertTrue(html.contains("var label = tokens[idx].meta && tokens[idx].meta.label ? String(tokens[idx].meta.label) : '';"))
        XCTAssertTrue(html.contains("border-radius: 999px;"))
        XCTAssertTrue(html.contains("height: 25px;"))
        XCTAssertTrue(html.contains("background: rgba(13, 13, 13, 0.04);"))
        XCTAssertFalse(html.contains("background: rgba(37, 99, 235, 0.14);"))
        XCTAssertTrue(html.contains(".hljs-keyword"))
        XCTAssertTrue(html.contains("window.__scopyIsRenderReady"))
        XCTAssertTrue(html.contains("requiresHighlightTheme"))
        XCTAssertTrue(html.contains("highlightThemeReady"))
    }

    func testMarkdownPreviewPreservesSoftLineBreaks() {
        let input = """
        **【试卷二】第 21 题**
        设函数 $y=f(x)$ 的定义域为 $D$，导函数为 $y=f'(x)$。
        (1) 若函数 $f(x)=\\ln x$，请判断该函数是否具有性质 $P(1)$；
        (2) 若函数 $f(x)=x^3+a$ 具有性质 $P(2)$；
        """

        let html = MarkdownHTMLRenderer.render(markdown: input)
        XCTAssertTrue(html.contains("breaks: true"))
    }

    func testMarkdownPreviewHeightReportingDoesNotDivideByDevicePixelRatio() {
        let html = MarkdownHTMLRenderer.render(markdown: "x")
        XCTAssertFalse(html.contains("devicePixelRatio"))
        XCTAssertTrue(html.contains("postMessage({ width: w, height: h"))
    }

    func testCJKEmphasisNormalizerFixesTrailingPunctuationAdjacentToCJKText() throws {
        let normalized = MarkdownCJKEmphasisNormalizer.normalize("**重要：**请注意")
        guard let sentinel = normalized.renderSentinel else {
            return XCTFail("Expected render sentinel for CJK emphasis normalization")
        }

        let html = try MarkdownItEngine.shared().render(normalized.markdown)
        let stripped = MarkdownCJKEmphasisNormalizer.stripRenderSentinel(
            from: html.trimmingCharacters(in: .whitespacesAndNewlines),
            sentinel: sentinel
        )
        XCTAssertEqual(stripped, "<p><strong>重要：</strong>请注意</p>")
    }

    func testCJKEmphasisNormalizerFixesBracketWrappedStrongAdjacentToCJKText() throws {
        let normalized = MarkdownCJKEmphasisNormalizer.normalize("这是**《重点》**内容")
        guard let sentinel = normalized.renderSentinel else {
            return XCTFail("Expected render sentinel for bracket-wrapped CJK emphasis")
        }

        let html = try MarkdownItEngine.shared().render(normalized.markdown)
        let stripped = MarkdownCJKEmphasisNormalizer.stripRenderSentinel(
            from: html.trimmingCharacters(in: .whitespacesAndNewlines),
            sentinel: sentinel
        )
        XCTAssertEqual(stripped, "<p>这是<strong>《重点》</strong>内容</p>")
    }

    func testCJKEmphasisNormalizerSkipsInlineCodeAndFencedCode() {
        let input = [
            "普通 **重要：**请注意",
            "",
            "`**重要：**请注意`",
            "",
            "```md",
            "**重要：**请注意",
            "```"
        ].joined(separator: "\n")

        let normalized = MarkdownCJKEmphasisNormalizer.normalize(input)
        guard let sentinel = normalized.renderSentinel else {
            return XCTFail("Expected render sentinel for mixed markdown input")
        }

        XCTAssertTrue(normalized.markdown.contains("普通 **重要：\(sentinel)**请注意"))
        XCTAssertTrue(normalized.markdown.contains("`**重要：**请注意`"))
        XCTAssertTrue(normalized.markdown.contains("```md\n**重要：**请注意\n```"))
    }

    func testMarkdownTableUsesChatGPTStyleWithExistingOverflowSupport() {
        let html = MarkdownHTMLRenderer.render(markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("wrapChatGPTTables(el);"))
        XCTAssertTrue(html.contains("scaleChatGPTTables(el);"))
        XCTAssertTrue(html.contains("window.__scopyScaleChatGPTTables = scaleChatGPTTables"))
        XCTAssertTrue(html.contains(".scopy-chatgpt-table-container"))
        XCTAssertFalse(MarkdownRenderFeatureSet.scopyDefault.overflowProbeSelector.contains(".scopy-chatgpt-table-container"))
        XCTAssertFalse(MarkdownRenderFeatureSet.scopyDefault.overflowProbeSelector.contains("table"))
        XCTAssertTrue(html.contains("overflow-x: auto;"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-thread-content-width: 768.0px;"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-render-width: calc(var(--scopy-chatgpt-thread-content-width) + (var(--scopy-chatgpt-content-inline-padding) * 2));"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-preview-scale: 1;"))
        XCTAssertTrue(html.contains("#content-scale-shell"))
        XCTAssertTrue(html.contains("width: var(--scopy-chatgpt-render-width);"))
        XCTAssertTrue(html.contains("transform: scale(var(--scopy-chatgpt-preview-scale));"))
        XCTAssertTrue(html.contains("updateChatGPTPreviewScale(el);"))
        XCTAssertTrue(html.contains("width: 100%;"))
        XCTAssertTrue(html.contains("max-width: 100%;"))
        XCTAssertTrue(html.contains("Table-local overflow should not request a wider Swift popover."))
        XCTAssertFalse(html.contains("document.scrollingElement || document.documentElement"))
        XCTAssertTrue(html.contains("display: table;"))
        XCTAssertTrue(html.contains("border-collapse: separate;"))
        XCTAssertTrue(html.contains("border: 0;"))
        XCTAssertTrue(html.contains("min-width: 100%;"))
        XCTAssertTrue(html.contains("width: 100%;"))
        XCTAssertTrue(html.contains("classifyChatGPTTable(wrapper, table);"))
        XCTAssertTrue(html.contains("scopy-chatgpt-wide-table"))
        XCTAssertTrue(html.contains("width: fit-content;"))
        XCTAssertTrue(html.contains("data-scopy-col-size"))
        XCTAssertTrue(html.contains("calc(var(--scopy-chatgpt-wide-table-col-baseline) * 14 / 24)"))
        XCTAssertTrue(html.contains("table-layout: auto;"))
        XCTAssertTrue(html.contains("dataset.scopyTableScaled"))
        XCTAssertTrue(html.contains("font-family: var(--scopy-chatgpt-font);"))
        XCTAssertTrue(html.contains("font-size: 14px;"))
        XCTAssertTrue(html.contains("line-height: 24px;"))
        XCTAssertFalse(html.contains("html.scopy-export-mode .scopy-chatgpt-table-container"))
        XCTAssertTrue(html.contains("text-align: start;"))
        XCTAssertTrue(html.contains("word-break: normal;"))
        XCTAssertTrue(html.contains("overflow-wrap: anywhere;"))
        XCTAssertFalse(html.contains("min-width: 128px;"))
        XCTAssertFalse(html.contains("max-width: 288px;"))
        XCTAssertTrue(html.contains("td:last-child"))
        XCTAssertTrue(html.contains("padding-inline: 8px;"))
        XCTAssertTrue(html.contains("padding-block: 8px;"))
        XCTAssertTrue(html.contains("line-height: 20px;"))
        XCTAssertTrue(html.contains("tbody td {"))
        XCTAssertTrue(html.contains("border-bottom: 1px solid var(--scopy-border-subtle);"))
        XCTAssertTrue(html.contains("padding-block: 10px;"))
        XCTAssertFalse(html.contains("padding-inline-end: 24px;"))
        XCTAssertFalse(html.contains("min-width: 224px;"))
        XCTAssertFalse(html.contains("max-width: 416px;"))
        XCTAssertTrue(html.contains("tbody tr:last-child td"))
        XCTAssertFalse(html.contains("display: block;\n            border-collapse: separate;"))
        XCTAssertFalse(html.contains("border-radius: 10px;"))
        XCTAssertFalse(html.contains("background: var(--scopy-table-header-bg);"))
        XCTAssertFalse(html.contains("border-left: 1px solid"))
    }

    func testMarkdownThemeUsesWACZChatGPTNonTableStyles() {
        let markdown = """
        # Title
        ## Section

        Paragraph with `code`, **strong**, *emphasis*, [link](https://example.com), and footnote.[^1]

        > Quote

        - [x] done
        - nested

        ```python
        def hello():
            print("hi")
        ```

        [^1]: note
        """

        let html = MarkdownHTMLRenderer.render(markdown: markdown)
        XCTAssertTrue(html.contains("--scopy-chatgpt-font:"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-mono:"))
        XCTAssertTrue(html.contains("--scopy-text-primary: rgb(13, 13, 13);"))
        XCTAssertTrue(html.contains("font-size: 16px;"))
        XCTAssertTrue(html.contains("line-height: 26px;"))
        XCTAssertTrue(html.contains("h1 {"))
        XCTAssertTrue(html.contains("font-size: 24px;"))
        XCTAssertTrue(html.contains("line-height: 32px;"))
        XCTAssertTrue(html.contains("h2 {"))
        XCTAssertTrue(html.contains("font-size: 20px;"))
        XCTAssertTrue(html.contains("h3 {"))
        XCTAssertTrue(html.contains("font-size: 18px;"))
        XCTAssertTrue(html.contains("p {"))
        XCTAssertTrue(html.contains("margin: 8px 0 4px 0;"))
        XCTAssertTrue(html.contains("p + p {"))
        XCTAssertTrue(html.contains("margin: 16px 0;"))
        XCTAssertTrue(html.contains("p code,"))
        XCTAssertTrue(html.contains("background: var(--scopy-code-bg);"))
        XCTAssertTrue(html.contains("white-space: nowrap;"))
        XCTAssertTrue(html.contains("h1 code,"))
        XCTAssertTrue(html.contains("#content h1 code,"))
        XCTAssertTrue(html.contains("h1 .qN-_1G_InlineCode"))
        XCTAssertTrue(html.contains("font-family: inherit;"))
        XCTAssertTrue(html.contains("background: transparent;"))
        XCTAssertTrue(html.contains("box-shadow: none;"))
        XCTAssertTrue(html.contains("pre {"))
        XCTAssertTrue(html.contains("border-radius: 24px;"))
        XCTAssertTrue(html.contains("padding: 48px 20px 12px 20px;"))
        XCTAssertTrue(html.contains("pre:has(> code.language-python)::before"))
        XCTAssertTrue(html.contains(".hljs-keyword"))
        XCTAssertTrue(html.contains("--scopy-syntax-keyword: #a626a4;"))
        XCTAssertTrue(html.contains("--scopy-syntax-string: #50a14f;"))
        XCTAssertTrue(html.contains("color: var(--scopy-syntax-keyword);"))
        XCTAssertTrue(html.contains("blockquote::after"))
        XCTAssertTrue(html.contains("padding: 4px 0 4px 24px;"))
        XCTAssertTrue(html.contains("top: 0;"))
        XCTAssertTrue(html.contains("bottom: 0;"))
        XCTAssertTrue(html.contains("background-color: var(--scopy-border);"))
        XCTAssertTrue(html.contains("li::marker"))
        XCTAssertTrue(html.contains("font-weight: 500;"))
        XCTAssertTrue(html.contains(".task-list-item-marker"))
        XCTAssertTrue(html.contains("list-style-type: none;"))
        XCTAssertTrue(html.contains("display: flex;"))
        XCTAssertTrue(html.contains("gap: 8px;"))
        XCTAssertTrue(html.contains("width: 16px;"))
        XCTAssertTrue(html.contains("border: 1px solid rgb(142, 142, 142);"))
        XCTAssertTrue(html.contains(".task-list-item-marker[data-checked=\"true\"]"))
        XCTAssertTrue(html.contains("background-color: rgb(0, 122, 255);"))
        XCTAssertTrue(html.contains("border-left: 2px solid #fff;"))
        XCTAssertTrue(html.contains("pointer-events: none;"))
        XCTAssertTrue(html.contains("var marker = document.createElement('span');"))
        XCTAssertTrue(html.contains("marker.setAttribute('role', 'checkbox');"))
        XCTAssertTrue(html.contains("hideNativeTaskInput(nativeInput);"))
        XCTAssertFalse(html.contains("marker.type = 'checkbox';"))
        XCTAssertTrue(html.contains("a::after"))
        XCTAssertTrue(html.contains("content: \"↗\";"))
        XCTAssertTrue(html.contains("sup.footnote-ref"))
        XCTAssertTrue(html.contains("height: 25px;"))
        XCTAssertTrue(html.contains("background: rgba(13, 13, 13, 0.04);"))
        XCTAssertFalse(html.contains("--scopy-surface-shadow"))
        XCTAssertFalse(html.contains("border-radius: 18px;"))
        XCTAssertFalse(html.contains("#eef2f7"))
        XCTAssertFalse(html.contains("#d73a49"))
    }

    func testMarkdownPreviewAndExportShareSafeContentInset() {
        let html = MarkdownHTMLRenderer.render(markdown: "# H1")
        XCTAssertTrue(html.contains("#content {"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-content-top-padding: 20.0px;"))
        XCTAssertTrue(html.contains("--scopy-chatgpt-content-inline-padding: 24.0px;"))
        XCTAssertTrue(html.contains("padding: var(--scopy-chatgpt-content-top-padding) var(--scopy-chatgpt-content-inline-padding) var(--scopy-chatgpt-content-bottom-padding) var(--scopy-chatgpt-content-inline-padding);"))
        XCTAssertTrue(html.contains("html.scopy-export-mode #content-scale-shell {"))
        XCTAssertTrue(html.contains("html.scopy-export-mode #content {"))
        XCTAssertTrue(html.contains("transform: none;"))
        XCTAssertFalse(html.contains("""
          html.scopy-export-mode #content {
            box-shadow: none;
            border: 0;
            border-radius: 0;
            padding: 0;
          }
        """))
    }

    func testKaTeXRenderToStringForTableSnippetMathSegments() throws {
        let input = #"""
        | 符号                                      | 含义                     |
        | --------------------------------------- | ---------------------- |
        | (\mathcal{U},\mathcal{I})               | 用户集合、物品集合              |
        | (\mathcal{E})                           | 观测到的交互集合               |
        | (\mathcal{N}_u,\mathcal{N}_i)           | 用户/物品的一阶邻居集合           |
        | (\mathcal{G}=(\mathcal{V},\mathcal{E})) | 用户—物品二部图               |
        | (\mathbf{A},\mathbf{D},\mathbf{L})      | 邻接矩阵、度矩阵、归一化拉普拉斯矩阵     |
        | (\mathbf{x}_i^{(m)})                    | 物品 (i) 的第 (m) 种模态特征    |
        | (\mathbf{e}_u,\mathbf{e}_i)             | 用户/物品潜在表示              |
        | (\hat{y}_{ui})                          | 用户 (u) 对物品 (i) 的预测偏好分数 |
        """#

        let segments = mathSegmentsForRender(markdown: input)
        XCTAssertFalse(segments.isEmpty)

        let engine = try KaTeXEngine.shared()
        for seg in segments {
            XCTAssertNoThrow(try engine.renderToString(latex: seg.expression, displayMode: seg.display))
        }
    }

    func testKaTeXRenderToStringForSpinWaveSnippet() throws {
        let input = #"""
        Here, we describe the formalism of the time-dependent spin wave theory and derive the effective Hamiltonian (5) of the main text.
        We consider a $d$-dimensional $N$ spin- $s$ system that is invariant under global spin rotations around the $z$-axis and spatial translations in the spin lattice.

        The corresponding Hamiltonian is

        $$
        H=-\sum_{i, j=1}^N J\left(\left|\mathbf{r}_i-\mathbf{r}_j\right|\right)\left[\hat{s}_i^x \hat{s}_j^x+\hat{s}_i^y \hat{s}_j^y+(1-\Delta) \hat{s}_i^z \hat{s}_j^z\right]-h \sum_{i=1}^N \hat{s}_i^z,
        $$

        where $\hat{s}_i^\mu=\hat{S}_i^\mu / s$ are the normalized spin- $s$ operators.

        We move to the rotated frame in which the expectation value of the magnetization operator, $\langle\hat{\mathbf{M}}(t)\rangle$ is always aligned with the $z$-axis.

        $$
        \hat{S}_i^\mu \rightarrow \tilde{S}_i=R_t \hat{S}_i^\mu R_t^{\dagger},
        $$

        where

        $$
        R_t=e^{-\mathrm{i} \phi_t \hat{M}^z} e^{-\mathrm{i} \theta_t \hat{M}^y}
        $$

        Accordingly, the Hamiltonian transforms into

        $$
        H \rightarrow \tilde{H}=H+\mathrm{i} R_t \partial_t R_t^{\dagger}
        $$

        Now we perform a semiclassical expansion by applying the HolsteinPrimakoff transformation,

        $$
        \tilde{S}_i^x \simeq \sqrt{\frac{s}{2}}\left(b_i^{\dagger}+b_i\right), \tilde{S}_i^y \simeq \mathrm{i} \sqrt{\frac{s}{2}}\left(b_i^{\dagger}-b_i\right), \tilde{S}_i^z=s-b_i^{\dagger} b_i
        $$
        """#

        let segments = mathSegmentsForRender(markdown: input)
        XCTAssertFalse(segments.isEmpty)

        let engine = try KaTeXEngine.shared()
        for seg in segments {
            XCTAssertNoThrow(try engine.renderToString(latex: seg.expression, displayMode: seg.display))
        }
    }

    func testKaTeXRenderToStringForCostVectorSnippetWithDropLastInText() throws {
        let input = #"""
        ### 3.1 输入与符号（全部都能从你 runtime 日志拿到）

        来自 warm‑up（按你大纲：warm‑up 用 L4 全服务）

        * (C^{base}*{io}, C^{base}*{aug}, C^{base}_{comp})（稳态均值，单位：秒/step 或 ms/step）
        * (C^{base}*{data}=C^{base}*{io}+C^{base}_{aug})
        * (C^{base}=\max(C^{base}*{data}, C^{base}*{comp}))

        来自 per‑level microbench（按你大纲的 cost 向量）

        * (\mathbf c^{(k)}=(c^{(k)}*{io},c^{(k)}*{aug},c^{(k)}_{comp}),\ k\in{0,1,2,3,4})
        * 以及（可选但强烈建议记录）按 level 分桶的命中率 (x_k)（I/O hit）与增强复用命中率 (h_k)（aug reuse hit），用于把 (c^{(k)}*{io},c^{(k)}*{aug}) 写成期望形式。

        来自 MSIS 调度输出

        * 投影后的比例 (\rho=[\rho_4,\rho_3,\rho_2,\rho_1,\rho_0])，以及执行后统计的 (\hat\rho)。

        来自训练任务的常量

        * 数据集大小 (N)，batch size (B)，每 epoch steps：
          [
          S=\left\lceil\frac{N}{B}\right\rceil \quad (\text{或使用 drop_last 对应的 } \left\lfloor\frac{N}{B}\right\rfloor)
          ]
        * epoch 数 (E) 或 time‑to‑accuracy 门槛对应的 epoch/step 数（来自实际训练曲线）。

        控制面开销

        * 每 epoch 的调度额外 CPU 时间：(t_{\text{imp}},t_{\text{alloc}},t_{\text{cachemeta}})，可直接从日志计时器拿到。
        """#

        let segments = mathSegmentsForRender(markdown: input)
        XCTAssertFalse(segments.isEmpty)

        let engine = try KaTeXEngine.shared()
        for seg in segments {
            XCTAssertNoThrow(try engine.renderToString(latex: seg.expression, displayMode: seg.display))
        }
    }

    func testKaTeXRenderToStringForExamQuestion21Snippet() throws {
        let input = #"""
        ### 第 21 题

        已知 $a \in \mathbf{R}$， $f(x) = 2x - \ln x + a$.

        (1) 求函数 $y = f(x)$ 的驻点；

        (2) 设 $g(x) = \begin{cases} f(x), & x > 0 \\ g(x+1), & x < 0 \end{cases}$，若关于 $x$ 的方程 $g(x) + g(-x) = 0$ 在区间 $(-1, 0)$ 内有解，求 $a$ 的取值范围；

        (3) 定义 $\text{sgn}(x) = \begin{cases} 1, & x > 0 \\ 0, & x = 0 \\ -1, & x < 0 \end{cases}$，设 $h(x) = 2x - (2x - f(x))\text{sgn}(2x - f(x))$， $h(x_0) = \frac{t}{a}$，若存在实数 $a$，使得 $\left\{ x \left| h(x) \ge \frac{t}{a} \right. \right\} \neq [x_0, +\infty)$，求实数 $t$ 的最小值.
        """#

        let segments = mathSegmentsForRender(markdown: input)
        XCTAssertGreaterThanOrEqual(segments.count, 6)
        for seg in segments {
            XCTAssertFalse(seg.expression.contains("SCOPYMATHPLACEHOLDER"))
        }

        let engine = try KaTeXEngine.shared()
        for seg in segments {
            XCTAssertNoThrow(try engine.renderToString(latex: seg.expression, displayMode: seg.display))
        }
    }

    // MARK: - Pipeline

    private struct Segment {
        let expression: String
        let display: Bool
    }

    private func mathSegmentsForRender(markdown: String) -> [Segment] {
        let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
        let normalized = MathNormalizer.wrapLooseLaTeX(latexNormalized)
        let protected = MathProtector.protectMath(in: normalized)

        var segments: [Segment] = []
        segments.reserveCapacity(protected.placeholders.count)

        let orderedDelimiters = MathEnvironmentSupport.katexAutoRenderDelimiters.sorted { a, b in
            a.left.count != b.left.count ? (a.left.count > b.left.count) : (a.right.count > b.right.count)
        }

        for original in protected.placeholders.map(\.original) {
            if let seg = extractSegment(from: original, delimiters: orderedDelimiters) {
                segments.append(seg)
            }
        }

        return segments
    }

    private func extractSegment(from original: String, delimiters: [MathEnvironmentSupport.Delimiter]) -> Segment? {
        for d in delimiters {
            guard original.hasPrefix(d.left), original.hasSuffix(d.right) else { continue }
            let innerStart = original.index(original.startIndex, offsetBy: d.left.count)
            let innerEnd = original.index(original.endIndex, offsetBy: -d.right.count)
            let inner = String(original[innerStart..<innerEnd])
            return Segment(expression: inner, display: d.display)
        }
        return nil
    }
}

private final class KaTeXEngine {
    private let context: JSContext

    static func shared() throws -> KaTeXEngine {
        try KaTeXEngine()
    }

    private init() throws {
        guard let context = JSContext() else {
            throw NSError(domain: "ScopyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create JSContext"])
        }
        self.context = context

        context.exceptionHandler = { _, exception in
            // Keep the exception available via `context.exception`.
            _ = exception
        }

        let baseURL = try markdownPreviewBaseURL()
        let katexURL = baseURL.appendingPathComponent("katex.min.js", isDirectory: false)
        let mhchemURL = baseURL.appendingPathComponent("contrib/mhchem.min.js", isDirectory: false)

        let katexSource = try String(contentsOf: katexURL, encoding: .utf8)
        context.evaluateScript(katexSource)
        if let exc = context.exception {
            throw NSError(domain: "ScopyTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "KaTeX JS exception: \(exc)"])
        }

        // mhchem is optional; load best-effort to match app runtime.
        if FileManager.default.fileExists(atPath: mhchemURL.path) {
            let mhchemSource = try String(contentsOf: mhchemURL, encoding: .utf8)
            context.evaluateScript(mhchemSource)
            context.exception = nil
        }
    }

    func renderToString(latex: String, displayMode: Bool) throws -> String {
        let katex = context.objectForKeyedSubscript("katex")
        guard let katex, !katex.isUndefined else {
            throw NSError(domain: "ScopyTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "KaTeX not available in JSContext"])
        }

        let options = JSValue(newObjectIn: context)
        options?.setValue(displayMode, forProperty: "displayMode")
        options?.setValue(true, forProperty: "throwOnError")
        options?.setValue("ignore", forProperty: "strict")

        let result = katex.invokeMethod("renderToString", withArguments: [latex, options as Any])
        if let exc = context.exception {
            context.exception = nil
            throw NSError(domain: "ScopyTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "KaTeX render exception: \(exc)"])
        }

        guard let s = result?.toString(), !s.isEmpty else {
            throw NSError(domain: "ScopyTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "KaTeX returned empty string"])
        }
        return s
    }

}

private final class MarkdownItEngine {
    private let context: JSContext

    static func shared() throws -> MarkdownItEngine {
        try MarkdownItEngine()
    }

    private init() throws {
        guard let context = JSContext() else {
            throw NSError(domain: "ScopyTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to create JSContext for markdown-it"])
        }
        self.context = context

        context.exceptionHandler = { _, exception in
            _ = exception
        }

        let baseURL = try markdownPreviewBaseURL()
        let markdownItURL = baseURL.appendingPathComponent("contrib/markdown-it.min.js", isDirectory: false)
        let source = try String(contentsOf: markdownItURL, encoding: .utf8)
        context.evaluateScript(source)
        if let exc = context.exception {
            throw NSError(domain: "ScopyTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "markdown-it JS exception: \(exc)"])
        }
    }

    func render(_ markdown: String) throws -> String {
        let markdownit = context.objectForKeyedSubscript("markdownit")
        guard let markdownit, !markdownit.isUndefined else {
            throw NSError(domain: "ScopyTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "markdown-it not available in JSContext"])
        }

        let options = JSValue(newObjectIn: context)
        options?.setValue(false, forProperty: "html")
        options?.setValue(true, forProperty: "linkify")
        options?.setValue(true, forProperty: "typographer")
        options?.setValue(true, forProperty: "breaks")

        let renderer = markdownit.call(withArguments: [options as Any])
        let result = renderer?.invokeMethod("render", withArguments: [markdown])
        if let exc = context.exception {
            context.exception = nil
            throw NSError(domain: "ScopyTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "markdown-it render exception: \(exc)"])
        }

        guard let html = result?.toString(), !html.isEmpty else {
            throw NSError(domain: "ScopyTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "markdown-it returned empty HTML"])
        }
        return html
    }
}

private func markdownPreviewBaseURL() throws -> URL {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let candidate = dir.appendingPathComponent("Scopy/Resources/MarkdownPreview", isDirectory: true)
        let katex = candidate.appendingPathComponent("katex.min.js", isDirectory: false)
        if fm.fileExists(atPath: katex.path) {
            return candidate
        }
        let next = dir.deletingLastPathComponent()
        if next.path == dir.path { break }
        dir = next
    }
    throw NSError(domain: "ScopyTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot locate Scopy/Resources/MarkdownPreview from test file path."])
}
