import Foundation

enum UnifiedMarkdownRenderer: MarkdownPreviewRenderer {
    static let kind: MarkdownRendererKind = .unified

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        let html = htmlDocument(markdown: markdown, context: context)
        let diagnostics = MarkdownRenderDiagnostics(
            renderer: .unified,
            profile: context.profile,
            policyVersion: context.policyVersion,
            protectedIslandCount: 0,
            explicitMathCount: MarkdownDetector.containsMath(markdown) ? 1 : 0,
            repairedMathCount: 0,
            fallbackReason: nil,
            warnings: []
        )
        return MarkdownRenderOutput(html: html, diagnostics: diagnostics)
    }

    private static func htmlDocument(markdown: String, context: MarkdownRenderContext) -> String {
        let markdownLiteral = jsonLiteral(markdown)
        let policyLiteral = jsonLiteral(policyPayload(context: context))
        let fallback = escapeHTML(markdown)

        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline' file:; script-src 'self' 'unsafe-inline' file:; font-src 'self' data: file:;">
            <link rel="stylesheet" href="katex.min.css">
            <script defer src="contrib/scopy-unified-renderer.iife.js"></script>
            <style>
              body {
                margin: 0;
                padding: 0;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
                font-size: 15px;
                line-height: 1.65;
                color: #0f172a;
                background: #eef2f7;
              }
              * { box-sizing: border-box; }
              #content {
                padding: 20px 18px;
                max-width: 100%;
                word-break: break-word;
                background: #ffffff;
                border: 1px solid rgba(15, 23, 42, 0.09);
                border-radius: 18px;
                box-shadow: 0 14px 38px rgba(15, 23, 42, 0.08);
              }
              pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
              pre {
                padding: 14px 16px;
                border-radius: 12px;
                overflow-x: auto;
                background: #f6f8fb;
              }
              img { max-width: 100%; height: auto; }
              a {
                pointer-events: none;
                color: #0a66d9;
                text-decoration: underline;
                text-underline-offset: 0.14em;
              }
              table {
                display: block;
                border-collapse: collapse;
                max-width: 100%;
                overflow-x: auto;
              }
              th, td {
                border: 1px solid rgba(127,127,127,0.25);
                padding: 8px 10px;
              }
              .katex-display {
                max-width: 100%;
                overflow-x: auto;
                overflow-y: hidden;
              }
            </style>
            <script>
              (function () {
                window.__scopyRenderState = window.__scopyRenderState || {
                  renderComplete: false,
                  markdownRendered: false,
                  renderPass: 0
                };
                var lastH = 0;
                var lastW = 0;
                window.__scopyIsRenderReady = function () {
                  try {
                    var state = window.__scopyRenderState || {};
                    return !!state.renderComplete && !!state.markdownRendered;
                  } catch (e) {
                    return false;
                  }
                };
                window.__scopyRenderMath = window.__scopyRenderMath || function () {
                  if (typeof window.__scopyReportHeight === 'function') {
                    window.__scopyReportHeight();
                  }
                };
                window.__scopyReportHeight = function (force) {
                  try {
                    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopySize) { return; }
                    var el = document.getElementById('content');
                    if (!el) { return; }
                    var rect = el.getBoundingClientRect();
                    var w = Math.ceil(rect.width || 0);
                    var h = Math.ceil(Math.max(rect.height || 0, el.scrollHeight || 0));
                    if (!h) { return; }
                    if (!force && Math.abs(h - lastH) < 1 && Math.abs(w - lastW) < 1) { return; }
                    lastH = h;
                    lastW = w;
                    window.webkit.messageHandlers.scopySize.postMessage({ width: w, height: h, overflowX: false });
                  } catch (e) { }
                };
                function finish() {
                  try {
                    if (window.__scopyRenderState) {
                      window.__scopyRenderState.markdownRendered = true;
                      window.__scopyRenderState.renderComplete = true;
                    }
                  } catch (e) { }
                  if (typeof window.__scopyReportHeight === 'function') {
                    window.__scopyReportHeight(true);
                    setTimeout(function () { window.__scopyReportHeight(true); }, 120);
                  }
                }
                function renderUnified() {
                  var el = document.getElementById('content');
                  if (!el) { return; }
                  try {
                    if (window.__scopyRenderState) {
                      window.__scopyRenderState.renderComplete = false;
                      window.__scopyRenderState.markdownRendered = false;
                      window.__scopyRenderState.renderPass = (window.__scopyRenderState.renderPass || 0) + 1;
                    }
                  } catch (e) { }
                  if (!window.ScopyUnifiedMarkdown || typeof window.ScopyUnifiedMarkdown.render !== 'function') {
                    setTimeout(renderUnified, 30);
                    return;
                  }
                  try {
                    var result = window.ScopyUnifiedMarkdown.render(\(markdownLiteral), \(policyLiteral));
                    el.innerHTML = result && result.html ? result.html : '<pre>\(fallback)</pre>';
                  } catch (e) {
                    el.innerHTML = '<pre>\(fallback)</pre>';
                  }
                  finish();
                }
                if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', renderUnified);
                } else {
                  renderUnified();
                }
              })();
            </script>
          </head>
          <body>
            <div id="content"><pre>\(fallback)</pre></div>
          </body>
        </html>
        """
    }

    private static func policyPayload(context: MarkdownRenderContext) -> [String: AnyEncodable] {
        [
            "profile": AnyEncodable(context.profile.rawValue),
            "allowExplicitMath": AnyEncodable(context.policy.allowExplicitMath),
            "allowBackslashMath": AnyEncodable(context.policy.allowBackslashMath),
            "allowLooseMathRepair": AnyEncodable(context.policy.allowLooseMathRepair),
            "allowSafeHTMLSubset": AnyEncodable(context.policy.allowSafeHTMLSubset),
            "allowRawHTML": AnyEncodable(context.policy.allowRawHTML),
            "policyVersion": AnyEncodable(context.policyVersion)
        ]
    }

    private static func escapeHTML(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        return s
    }

    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return s.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
