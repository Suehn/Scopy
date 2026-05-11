import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let context = MarkdownRenderContextResolver.defaultContext(for: markdown)
        return render(markdown: markdown, context: context).html
    }

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownPreviewRendererFacade.render(markdown: markdown, context: context)
    }

    static func renderLegacy(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        let featureSet = MarkdownRenderFeatureSet.scopyDefault
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let syntaxProtected = MarkdownSyntaxProtector.protectForLooseMathRepair(markdown)
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let latexNormalized = context.policy.allowLatexDocumentNormalize
            ? LaTeXDocumentNormalizer.normalize(syntaxProtected.markdown)
            : syntaxProtected.markdown
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let looseMathNormalized = context.policy.allowLooseMathRepair
            ? MathNormalizer.wrapLooseLaTeX(latexNormalized)
            : latexNormalized
        let normalizedMarkdown = MarkdownSyntaxProtector.restore(
            looseMathNormalized,
            placeholders: syntaxProtected.placeholders
        )
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let inlineNormalizedMarkdown = context.policy.allowLatexInlineTextNormalize
            ? LaTeXInlineTextNormalizer.normalize(protected.markdown)
            : protected.markdown
        let normalizedHeadingsMarkdown = normalizeATXHeadings(in: inlineNormalizedMarkdown)
        let emphasisNormalizedMarkdown = MarkdownCJKEmphasisNormalizer.normalize(normalizedHeadingsMarkdown)
        let safeHTMLExtraction = featureSet.safeHTMLSubset && context.policy.allowSafeHTMLSubset
            ? MarkdownSafeHTMLSubset.extract(from: emphasisNormalizedMarkdown.markdown)
            : MarkdownSafeHTMLExtractionResult(
                markdown: emphasisNormalizedMarkdown.markdown,
                fallbackMarkdown: emphasisNormalizedMarkdown.markdown,
                replacements: [:]
            )
        let renderMarkdown = safeHTMLExtraction.markdown
        let hasMath = context.policy.allowExplicitMath && MarkdownDetector.containsMath(normalizedMarkdown)
        let enableMath = featureSet.math && hasMath

        let fallbackText = MarkdownCJKEmphasisNormalizer.stripRenderSentinel(
            from: MathProtector.restoreMath(
                in: safeHTMLExtraction.fallbackMarkdown,
                placeholders: protected.placeholders,
                escape: { $0 }
            ),
            sentinel: emphasisNormalizedMarkdown.renderSentinel
        )

        guard !Task.isCancelled else { return cancelledOutput(context: context) }
        let html = MarkdownHTMLDocumentBuilder.legacyDocument(
            featureSet: featureSet,
            markdown: renderMarkdown,
            placeholders: protected.placeholders,
            safeHTMLReplacements: safeHTMLExtraction.replacements,
            enableMath: enableMath,
            fallbackText: fallbackText,
            renderSentinel: emphasisNormalizedMarkdown.renderSentinel
        )
        let diagnostics = MarkdownRenderDiagnostics.legacy(
            context: context,
            protectedIslandCount: syntaxProtected.placeholders.count,
            explicitMathCount: protected.placeholders.count
        )
        return MarkdownRenderOutput(html: html, diagnostics: diagnostics)
    }

    private static func cancelledOutput(context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownRenderOutput(
            html: "",
            diagnostics: MarkdownRenderDiagnostics.legacy(
                context: context,
                protectedIslandCount: 0,
                explicitMathCount: 0,
                warnings: ["render cancelled"]
            )
        )
    }

    /// Best-effort: normalize ATX headings like `##标题` -> `## 标题`.
    /// Some Markdown sources omit the required space after `#`, which makes heading levels look identical (plain text).
    private static func normalizeATXHeadings(in markdown: String) -> String {
        guard markdown.contains("#") else { return markdown }

        var out: [String] = []
        out.reserveCapacity(markdown.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFence: (marker: Character, count: Int)?
        for lineSub in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)

            if let (marker, count) = MarkdownCodeSkipper.fencePrefix(in: line) {
                if let current = inFence {
                    if current.marker == marker, count >= current.count {
                        inFence = nil
                    }
                } else {
                    inFence = (marker: marker, count: count)
                }
                out.append(line)
                continue
            }

            if inFence != nil {
                out.append(line)
                continue
            }

            // Avoid altering indented code blocks.
            var i = line.startIndex
            var leadingSpaces = 0
            while i < line.endIndex, line[i] == " " {
                leadingSpaces += 1
                i = line.index(after: i)
            }
            if leadingSpaces > 3 {
                out.append(line)
                continue
            }

            guard i < line.endIndex, line[i] == "#" else {
                out.append(line)
                continue
            }

            var j = i
            var hashCount = 0
            while j < line.endIndex, line[j] == "#" {
                hashCount += 1
                j = line.index(after: j)
            }

            guard (1...6).contains(hashCount), j < line.endIndex else {
                out.append(line)
                continue
            }

            let next = line[j]
            if next == " " || next == "\t" {
                out.append(line)
                continue
            }
            // Avoid shebang-like patterns in plain text.
            if hashCount == 1, next == "!" {
                out.append(line)
                continue
            }

            let prefix = String(line[..<j])
            let rest = String(line[j...])
            out.append(prefix + " " + rest)
        }

        return out.joined(separator: "\n")
    }
}
