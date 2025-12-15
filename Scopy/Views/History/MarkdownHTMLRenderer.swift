import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
        let normalizedMarkdown = MathNormalizer.wrapLooseLaTeX(latexNormalized)
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        let inlineNormalizedMarkdown = LaTeXInlineTextNormalizer.normalize(protected.markdown)
        let hasMath = MarkdownDetector.containsMath(normalizedMarkdown)

        let fallbackText = MathProtector.restoreMath(
            in: inlineNormalizedMarkdown,
            placeholders: protected.placeholders,
            escape: { $0 }
        )

        return htmlDocument(
            markdown: inlineNormalizedMarkdown,
            placeholders: protected.placeholders,
            enableMath: hasMath,
            fallbackText: fallbackText
        )
    }

    private static let cspMetaTag = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline' file:; script-src 'self' 'unsafe-inline' file:; font-src 'self' data: file:;">
    """

    private static let baseStyle = """
    <style>
      :root { color-scheme: light dark; }
      body {
        margin: 0;
        padding: 16px;
        font: -apple-system-body;
        line-height: 1.45;
        background: transparent;
      }
      #content { word-break: break-word; }
      pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      pre {
        padding: 12px;
        border-radius: 8px;
        overflow-x: auto;
      }
      img { max-width: 100%; height: auto; }
      a { pointer-events: none; text-decoration: underline; }
      blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,0.35); }
      hr { border: 0; border-top: 1px solid rgba(127,127,127,0.35); margin: 12px 0; }
      table {
        display: block;
        border-collapse: collapse;
        max-width: 100%;
        overflow-x: auto;
        -webkit-overflow-scrolling: touch;
        width: max-content;
        min-width: 100%;
      }
      th, td {
        border: 1px solid rgba(127,127,127,0.25);
        padding: 6px 8px;
        vertical-align: top;
        white-space: normal;
        word-break: normal;
        overflow-wrap: break-word;
        max-width: 520px;
      }
      thead th { background: rgba(127,127,127,0.10); }
    </style>
    """

    private static func htmlDocument(
        markdown: String,
        placeholders: [(placeholder: String, original: String)],
        enableMath: Bool,
        fallbackText: String
    ) -> String {
        let mathIncludes: String
        if enableMath {
            let delimitersLiteral = MathEnvironmentSupport.katexDelimitersJSArrayLiteral()
            mathIncludes = """
            <link rel="stylesheet" href="katex.min.css">
            <script defer src="katex.min.js"></script>
            <script defer src="contrib/mhchem.min.js"></script>
            <script defer src="contrib/auto-render.min.js"></script>
            <script>
              (function () {
                window.__scopyRenderMath = function () {
                  var el = document.getElementById('content');
                  if (!el) { return; }
                  if (typeof renderMathInElement !== 'function') { return; }
                  renderMathInElement(el, {
                    delimiters: \(delimitersLiteral),
                    throwOnError: false,
                    strict: 'ignore',
                    ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
                  });
                  if (typeof window.__scopyReportHeight === 'function') {
                    window.__scopyReportHeight();
                  }
                };

                function tryRender() {
                  if (typeof window.__scopyRenderMath !== 'function') { return; }
                  if (typeof renderMathInElement !== 'function') {
                    setTimeout(tryRender, 30);
                    return;
                  }
                  window.__scopyRenderMath();
                }

                if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', tryRender);
                } else {
                  tryRender();
                }
              })();
            </script>
            """
        } else {
            mathIncludes = ""
        }

        let markdownLiteral = jsonStringLiteral(markdown)
        let placeholderMap: [String: String] = Dictionary(uniqueKeysWithValues: placeholders.map { ($0.placeholder, escapeHTML($0.original)) })
        let placeholdersLiteral = jsonStringLiteral(placeholderMap)

        let markdownRenderScript = """
        <script defer src="contrib/markdown-it.min.js"></script>
        <script>
          (function () {
            var lastHeight = 0;
            window.__scopyReportHeight = function () {
              try {
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopyHeight) { return; }
                var h = Math.max(document.body.scrollHeight || 0, document.documentElement.scrollHeight || 0);
                var dpr = window.devicePixelRatio || 1;
                var hp = h / dpr;
                if (!hp) { return; }
                if (Math.abs(hp - lastHeight) < 1) { return; }
                lastHeight = hp;
                window.webkit.messageHandlers.scopyHeight.postMessage(hp);
              } catch (e) { }
            };

            function scheduleReportHeight() {
              if (typeof window.__scopyReportHeight !== 'function') { return; }
              if (typeof window.requestAnimationFrame === 'function') {
                window.requestAnimationFrame(window.__scopyReportHeight);
              } else {
                setTimeout(window.__scopyReportHeight, 0);
              }
            }

            function renderMarkdown() {
              var el = document.getElementById('content');
              if (!el) { return; }
              if (typeof window.markdownit !== 'function') {
                setTimeout(renderMarkdown, 30);
                return;
              }

              var md = window.markdownit({ html: false, linkify: false, typographer: true });
              if (md && typeof md.enable === 'function') {
                md.enable('table');
              }
              var src = \(markdownLiteral);
              var html = md.render(src);
              var map = \(placeholdersLiteral);
              html = html.replace(/SCOPYMATHPLACEHOLDER\\d+X/g, function (m) { return map[m] || m; });
              el.innerHTML = html;

              if (typeof window.__scopyRenderMath === 'function') {
                window.__scopyRenderMath();
              }
              scheduleReportHeight();
              setTimeout(scheduleReportHeight, 120);
            }

            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', renderMarkdown);
            } else {
              renderMarkdown();
            }
          })();
        </script>
        """

        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            \(cspMetaTag)
            \(markdownRenderScript)
            \(mathIncludes)
            \(baseStyle)
          </head>
          <body>
            <div id="content"><pre>\(escapeHTML(fallbackText))</pre></div>
          </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        return s
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        // A JSON literal is a safe JS literal for our use (no interpolation or eval).
        // Use JSONEncoder to avoid NSJSONSerialization raising NSException on top-level fragments.
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "\"\""
        // Prevent `</script>` from prematurely terminating our inline script tag.
        return s.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }

    private static func jsonStringLiteral(_ value: [String: String]) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return s.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }
}
