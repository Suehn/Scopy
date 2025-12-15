import Foundation
import JavaScriptCore
import XCTest

final class KaTeXRenderToStringTests: XCTestCase {
    func testMarkdownRendererEnablesTables() {
        let html = MarkdownHTMLRenderer.render(markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("md.enable('table')"))
        XCTAssertTrue(html.contains("markdown-it.min.js"))
    }

    func testMarkdownTableUsesHorizontalScrollWithBalancedWrapping() {
        let html = MarkdownHTMLRenderer.render(markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("overflow-x: auto;"))
        XCTAssertTrue(html.contains("white-space: normal;"))
        XCTAssertTrue(html.contains("word-break: normal;"))
        XCTAssertTrue(html.contains("max-width: 520px;"))
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
    private static var cached: KaTeXEngine?
    private let context: JSContext

    static func shared() throws -> KaTeXEngine {
        if let cached { return cached }
        let engine = try KaTeXEngine()
        cached = engine
        return engine
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

        let baseURL = try Self.markdownPreviewBaseURL()
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

    private static func markdownPreviewBaseURL() throws -> URL {
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
}
