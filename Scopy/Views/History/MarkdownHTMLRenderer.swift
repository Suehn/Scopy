import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        guard !Task.isCancelled else { return "" }
        let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
        guard !Task.isCancelled else { return "" }
        let normalizedMarkdown = MathNormalizer.wrapLooseLaTeX(latexNormalized)
        guard !Task.isCancelled else { return "" }
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        guard !Task.isCancelled else { return "" }
        let inlineNormalizedMarkdown = LaTeXInlineTextNormalizer.normalize(protected.markdown)
        let renderMarkdown = normalizeATXHeadings(in: inlineNormalizedMarkdown)
        let hasMath = MarkdownDetector.containsMath(normalizedMarkdown)

        let fallbackText = MathProtector.restoreMath(
            in: renderMarkdown,
            placeholders: protected.placeholders,
            escape: { $0 }
        )

        guard !Task.isCancelled else { return "" }
        return htmlDocument(
            markdown: renderMarkdown,
            placeholders: protected.placeholders,
            enableMath: hasMath,
            fallbackText: fallbackText
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

    private static let cspMetaTag = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline' file:; script-src 'self' 'unsafe-inline' file:; font-src 'self' data: file:;">
    """

    private static let baseStyle = """
    <style>
      :root { color-scheme: light dark; }
      body {
        margin: 0;
        padding: 0;
        font: -apple-system-body;
        line-height: 1.45;
        background: transparent;
      }
      html, body { overflow-x: hidden; }
      #content {
        padding: 16px;
        display: inline-block;
        max-width: 100%;
        box-sizing: border-box;
        word-break: break-word;
        opacity: 0;
        transition: opacity 140ms ease-in-out;
      }
      pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      pre {
        padding: 12px;
        border-radius: 8px;
        overflow-x: auto;
        max-width: 100%;
        box-sizing: border-box;
      }
      img { max-width: 100%; height: auto; }
      a { pointer-events: none; text-decoration: underline; }
      blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,0.35); }
      hr { border: 0; border-top: 1px solid rgba(127,127,127,0.35); margin: 12px 0; }
      .katex-display {
        max-width: 100%;
        overflow-x: auto;
        overflow-y: hidden;
      }
      table {
        display: block;
        border-collapse: collapse;
        max-width: 100%;
        overflow-x: auto;
        width: 100%;
        table-layout: auto;
      }
      th, td {
        border: 1px solid rgba(127,127,127,0.25);
        padding: 6px 8px;
        vertical-align: top;
        white-space: nowrap;
        word-break: normal;
        overflow-wrap: normal;
      }
      thead th { background: rgba(127,127,127,0.10); }

      /* Hide scrollbars inside HTML when idle (even if system setting is "always show scroll bars").
         We show them temporarily while the user is actively scrolling overflow containers (JS toggles the class). */
      pre::-webkit-scrollbar,
      table::-webkit-scrollbar,
      .katex-display::-webkit-scrollbar {
        width: 0px;
        height: 0px;
      }
      html.scopy-scrollbars-visible pre::-webkit-scrollbar,
      html.scopy-scrollbars-visible table::-webkit-scrollbar,
      html.scopy-scrollbars-visible .katex-display::-webkit-scrollbar {
        width: 8px;
        height: 8px;
      }
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
            var lastH = 0;
            var lastW = 0;
            var pendingRAF = false;
            var ro = null;
            window.__scopyReportHeight = function (force) {
              try {
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopySize) { return; }
                var el = document.getElementById('content');
                if (!el) { return; }
                var rect = el.getBoundingClientRect();
                var w = Math.ceil(rect.width || 0);
                var sh = Math.ceil(el.scrollHeight || 0);
                var h = Math.ceil(Math.max(rect.height || 0, sh));
                var overflowX = false;
                try {
                  // Detect horizontal scroll requirement inside common overflow containers (KaTeX display, code blocks, tables).
                  // We use this signal to prefer a wider popover, while keeping the outer scroll view's horizontal scroller disabled.
                  var nodes = el.querySelectorAll('pre, table, .katex-display');
                  for (var i = 0; i < nodes.length; i++) {
                    var n = nodes[i];
                    if (!n) { continue; }
                    var cw = n.clientWidth || 0;
                    var sw = n.scrollWidth || 0;
                    if (cw > 0 && (sw - cw) > 1) { overflowX = true; break; }
                  }
                  if (!overflowX) {
                    var se = document.scrollingElement || document.documentElement;
                    overflowX = !!se && ((se.scrollWidth || 0) - (se.clientWidth || 0) > 2);
                  }
                } catch (e) { overflowX = false; }
                if (!h) { return; }
                if (!force && Math.abs(h - lastH) < 1 && Math.abs(w - lastW) < 1) { return; }
                lastH = h;
                lastW = w;
                window.webkit.messageHandlers.scopySize.postMessage({ width: w, height: h, overflowX: overflowX });
              } catch (e) { }
            };

            function scheduleReportHeight() {
              if (typeof window.__scopyReportHeight !== 'function') { return; }
              if (pendingRAF) { return; }
              pendingRAF = true;
              if (typeof window.requestAnimationFrame === 'function') {
                window.requestAnimationFrame(function () {
                  pendingRAF = false;
                  window.__scopyReportHeight();
                });
              } else {
                setTimeout(function () {
                  pendingRAF = false;
                  window.__scopyReportHeight();
                }, 0);
              }
            }

            function renderMarkdown() {
              var el = document.getElementById('content');
              if (!el) { return; }
              if (typeof window.markdownit !== 'function') {
                setTimeout(renderMarkdown, 30);
                return;
              }
              // Keep it hidden until the final layout (including KaTeX) is applied; SwiftUI shows a text fallback underneath.
              try { el.style.opacity = '0'; } catch (e) { }

              var scrollbarHideTimer = null;
              function showScrollbarsTemporarily() {
                try {
                  var root = document.documentElement;
                  if (!root) { return; }
                  root.classList.add('scopy-scrollbars-visible');
                  if (scrollbarHideTimer) { clearTimeout(scrollbarHideTimer); }
                  scrollbarHideTimer = setTimeout(function () {
                    try { root.classList.remove('scopy-scrollbars-visible'); } catch (e) { }
                  }, 700);
                } catch (e) { }
              }
              function isOverflowContainerEventTarget(t) {
                try {
                  if (!t) { return false; }
                  // Element nodes only. Document scrolling is very high frequency and should not toggle scrollbars.
                  if (t.nodeType !== 1) { return false; }
                  if (t.matches && t.matches('pre, table, .katex-display')) { return true; }
                  if (t.closest && t.closest('pre, table, .katex-display')) { return true; }
                } catch (e) { }
                return false;
              }
              // `scroll` doesn't bubble; capture phase catches it from overflow containers (pre/table/katex-display).
              // Avoid toggling on main document scroll to keep vertical scrolling smooth for long content.
              try {
                document.addEventListener('scroll', function (ev) {
                  try {
                    if (!ev) { return; }
                    if (!isOverflowContainerEventTarget(ev.target)) { return; }
                    showScrollbarsTemporarily();
                  } catch (e) { }
                }, true);
              } catch (e) { }
              try {
                document.addEventListener('wheel', function (ev) {
                  try {
                    if (!ev) { return; }
                    if (!isOverflowContainerEventTarget(ev.target)) { return; }
                    showScrollbarsTemporarily();
                  } catch (e) { }
                }, { passive: true });
              } catch (e) { }

              // Preserve single newlines as hard line breaks. Clipboard/PDF copied text often uses line breaks
              // without blank lines, and the hover preview should respect that formatting.
              var md = window.markdownit({ html: false, linkify: false, typographer: true, breaks: true });
              if (md && typeof md.enable === 'function') {
                md.enable('table');
              }
              var src = \(markdownLiteral);
              var html = md.render(src);
              var map = \(placeholdersLiteral);
              html = html.replace(/SCOPYMATHPLACEHOLDER\\d+X/g, function (m) { return map[m] || m; });
              el.innerHTML = html;

              // Keep content height in sync as KaTeX renders and fonts load.
              if (typeof ResizeObserver === 'function') {
                if (ro) { try { ro.disconnect(); } catch (e) { } }
                ro = new ResizeObserver(function () { scheduleReportHeight(); });
                try { ro.observe(el); } catch (e) { }
              }

              if (document.fonts && document.fonts.ready && typeof document.fonts.ready.then === 'function') {
                document.fonts.ready.then(function () { scheduleReportHeight(); }).catch(function () { });
              }

              if (typeof window.__scopyRenderMath === 'function') {
                window.__scopyRenderMath();
              }
              try { el.style.opacity = '1'; } catch (e) { }
              scheduleReportHeight();
              setTimeout(scheduleReportHeight, 120);
            }

            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', renderMarkdown);
            } else {
              renderMarkdown();
            }

            // Some layout changes may only settle after full load.
            if (window && typeof window.addEventListener === 'function') {
              window.addEventListener('load', function () {
                scheduleReportHeight();
                setTimeout(scheduleReportHeight, 120);
              });
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
