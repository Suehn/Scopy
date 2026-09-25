import Foundation
import ScopyKit

/// Builds the one standalone Markdown document that preview and PNG export both load. It is a thin shell around
/// the renderer package (`Tools/MarkdownRenderer`): the base stylesheet `scopy-document.css`, the KaTeX stylesheet,
/// and the renderer bundle whose document runtime (`window.ScopyDocument`) renders the embedded input. The shell
/// adds only the layout variables for the chosen scale and the source plus render policy as JSON data.
enum MarkdownHTMLDocumentBuilder {
    private static let layout = MarkdownRenderLayoutConstants.self

    /// The document for `source` with the context its profile detector and frozen enrichment select.
    static func document(source: String) -> String {
        document(source: source, context: MarkdownRenderContextResolver.defaultContext(for: source))
    }

    /// The document for `source` under `context`. Swift never rewrites the source: every repair runs in the
    /// renderer bundle, gated by the embedded policy.
    static func document(source: String, context: MarkdownRenderContext) -> String {
        """
        <!doctype html>
        <html data-scopy-render-id="\(MarkdownPreviewRenderIdentity.placeholder)">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'; img-src 'self' data: scopy-source-icon:; style-src 'self' 'unsafe-inline' file:; script-src 'self' file:; font-src 'self' data: file:;">
            <link id="scopy-katex-stylesheet" rel="stylesheet" href="katex.min.css">
            <link id="scopy-document-stylesheet" rel="stylesheet" href="scopy-document.css">
            <style>\(layoutVariables(context.layoutScale))</style>
            <script type="application/json" id="scopy-render-input">\(jsonLiteral(RenderInput(policy: policyPayload(context: context), source: source)))</script>
            <script defer src="contrib/scopy-unified-renderer.iife.js"></script>
          </head>
          <body>
            <div id="content-scale-shell"><div id="content" dir="auto"></div></div>
          </body>
        </html>
        """
    }

    /// The nine layout variables that depend on the selected ChatGPT layout scale; every other token lives in
    /// `scopy-document.css`.
    private static func layoutVariables(_ layoutScale: MarkdownChatGPTLayoutScalePercent) -> String {
        let outputSurfaceWidth = layout.chatGPTOutputSurfaceWidth
        let layoutViewportWidth = layoutScale.layoutViewportWidth(outputSurfaceWidth: outputSurfaceWidth)
        let threadContentWidth = layout.threadContentWidth(forLayoutViewportWidth: layoutViewportWidth)
        return """
        :root { \
        --scopy-chatgpt-layout-font-scale: \(layoutScale.fontScale); \
        --scopy-chatgpt-browser-zoom: \(layoutScale.browserZoomScale); \
        --scopy-chatgpt-inverse-browser-zoom: \(layoutScale.inverseBrowserZoomScale); \
        --scopy-chatgpt-output-surface-width: \(outputSurfaceWidth)px; \
        --scopy-chatgpt-layout-viewport-width: \(layoutViewportWidth)px; \
        --scopy-chatgpt-thread-content-max-width: \(threadContentWidth)px; \
        --scopy-chatgpt-content-inline-padding: \(layout.chatGPTContentInlinePadding)px; \
        --scopy-chatgpt-content-top-padding: \(layout.chatGPTContentTopPadding)px; \
        --scopy-chatgpt-content-bottom-padding: \(layout.chatGPTContentBottomPadding)px; }
        """
    }

    /// Sorted keys make the document bytes a function of the input alone. The default `/` escaping
    /// (`<\/head>`, `<\/script>`) keeps embedded source from closing the shell's own elements; the replacements
    /// below are a second line of defense (`<!--` would otherwise let a later `<script` swallow the closing tag).
    /// Do not add `.withoutEscapingSlashes`.
    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return s
            .replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
            .replacingOccurrences(of: "<!--", with: "<\\u0021--")
    }

    /// The policy object embedded next to the source. `render.js#normalizePolicy` reads exactly
    /// these keys; `MarkdownRenderingCorpusContractTests` pins its bytes in the rendered document against the
    /// shared fixture `Tools/MarkdownRenderer/test/fixtures/policy-contract.json`.
    private static func policyPayload(context: MarkdownRenderContext) -> RenderPolicyPayload {
        RenderPolicyPayload(
            allowLatexDocumentNormalize: context.policy.allowLatexDocumentNormalize,
            allowLatexInlineTextNormalize: context.policy.allowLatexInlineTextNormalize,
            allowLooseMathRepair: context.policy.allowLooseMathRepair,
            linkEnrichment: context.linkEnrichment.flatMap { $0.entries.isEmpty ? nil : $0.entries }
        )
    }

    private struct RenderInput: Encodable {
        let policy: RenderPolicyPayload
        let source: String
    }

    private struct RenderPolicyPayload: Encodable {
        let allowLatexDocumentNormalize: Bool
        let allowLatexInlineTextNormalize: Bool
        let allowLooseMathRepair: Bool
        /// Omitted when there is no frozen sidecar or it is empty, so plain documents share one payload.
        let linkEnrichment: [String: LinkEnrichmentEntry]?
    }
}
