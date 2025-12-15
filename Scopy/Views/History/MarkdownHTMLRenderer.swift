import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
        let normalizedMarkdown = MathNormalizer.wrapLooseLaTeX(latexNormalized)
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        let hasMath = MarkdownDetector.containsMath(normalizedMarkdown)

        let fallbackText = MathProtector.restoreMath(
            in: protected.markdown,
            placeholders: protected.placeholders,
            escape: { $0 }
        )

        return htmlDocument(
            markdown: protected.markdown,
            placeholders: protected.placeholders,
            enableMath: hasMath,
            fallbackText: fallbackText
        )
    }

    private static func htmlDocument(
        markdown: String,
        placeholders: [(placeholder: String, original: String)],
        enableMath: Bool,
        fallbackText: String
    ) -> String {
        let mathIncludes: String
        if enableMath {
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
                    delimiters: [
                      {left: '$$', right: '$$', display: true},
                      {left: '$', right: '$', display: false},
                      {left: '\\\\[', right: '\\\\]', display: true},
                      {left: '\\\\(', right: '\\\\)', display: false},
                      {left: '\\\\begin{equation}', right: '\\\\end{equation}', display: true},
                      {left: '\\\\begin{align}', right: '\\\\end{align}', display: true},
                      {left: '\\\\begin{aligned}', right: '\\\\end{aligned}', display: true},
                      {left: '\\\\begin{cases}', right: '\\\\end{cases}', display: true}
                    ],
                    throwOnError: false,
                    strict: 'ignore',
                    ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
                  });
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
        let placeholderPairs: [[String]] = placeholders.map { [$0.placeholder, escapeHTML($0.original)] }
        let placeholdersLiteral = jsonStringLiteral(placeholderPairs)

        let markdownRenderScript = """
        <script defer src="contrib/markdown-it.min.js"></script>
        <script>
          (function () {
            function renderMarkdown() {
              var el = document.getElementById('content');
              if (!el) { return; }
              if (typeof window.markdownit !== 'function') {
                setTimeout(renderMarkdown, 30);
                return;
              }

              var md = window.markdownit({ html: false, linkify: false, typographer: true });
              var src = \(markdownLiteral);
              var html = md.render(src);
              var pairs = \(placeholdersLiteral);
              for (var i = 0; i < pairs.length; i++) {
                var key = pairs[i][0];
                var val = pairs[i][1];
                html = html.split(key).join(val);
              }
              el.innerHTML = html;

              if (typeof window.__scopyRenderMath === 'function') {
                window.__scopyRenderMath();
              }
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
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data: file:; style-src 'self' 'unsafe-inline' file:; script-src 'self' 'unsafe-inline' file:; font-src 'self' data: file:;">
            \(markdownRenderScript)
            \(mathIncludes)
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
              table { border-collapse: collapse; width: 100%; }
              th, td { border: 1px solid rgba(127,127,127,0.25); padding: 6px 8px; vertical-align: top; }
              thead th { background: rgba(127,127,127,0.10); }
            </style>
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
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private static func jsonStringLiteral(_ value: [[String]]) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
