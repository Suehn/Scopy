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
        let hasMath = MarkdownDetector.containsMath(normalizedMarkdown)

        let fallbackText = MathProtector.restoreMath(
            in: inlineNormalizedMarkdown,
            placeholders: protected.placeholders,
            escape: { $0 }
        )

        guard !Task.isCancelled else { return "" }
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
        -webkit-overflow-scrolling: touch;
      }
      table {
        display: block;
        border-collapse: collapse;
        max-width: 100%;
        overflow-x: auto;
        -webkit-overflow-scrolling: touch;
        width: 100%;
        table-layout: fixed;
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

      /* Hide scrollbars inside HTML when idle (even if system setting is "always show scroll bars").
         We show them temporarily while the user is actively scrolling (JS toggles the class). */
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

      /* Export-only appearance: force light theme (white background + black text) for snapshotting. */
      html.scopy-export-light { color-scheme: light !important; }
      html.scopy-export-light,
      html.scopy-export-light body {
        background: #ffffff !important;
        color: #000000 !important;
      }
      html.scopy-export-light #content { opacity: 1 !important; }
      html.scopy-export-light a { color: #000000 !important; }
      html.scopy-export-light pre { background: rgba(0,0,0,0.04) !important; }
      html.scopy-export-light blockquote { border-left-color: rgba(0,0,0,0.28) !important; }
      html.scopy-export-light hr { border-top-color: rgba(0,0,0,0.28) !important; }
      html.scopy-export-light th, html.scopy-export-light td { border-color: rgba(0,0,0,0.22) !important; }
      html.scopy-export-light thead th { background: rgba(0,0,0,0.06) !important; }
      html.scopy-export-light .katex { color: #000000 !important; }

      /* Export-only: keep the document width fixed, but scale tables (only tables) to avoid horizontal clipping.
         We do this with a wrapper + CSS transform so layout measurement remains reliable (avoid `zoom`). */
      html.scopy-export-light table {
        display: table !important;
        overflow: visible !important;
        max-width: none !important;
        width: -webkit-max-content !important;
        width: max-content !important;
        table-layout: auto !important;
      }
      html.scopy-export-light .scopy-table-export-wrap {
        width: 100%;
        max-width: 100%;
        overflow-x: hidden;
        overflow-y: visible;
      }
      html.scopy-export-light .scopy-table-export-inner {
        display: inline-block;
        transform-origin: top left;
      }

      /* Never include scrollbars in exported snapshot (even if scrolling recently toggled them on). */
      html.scopy-export-light pre::-webkit-scrollbar,
      html.scopy-export-light table::-webkit-scrollbar,
      html.scopy-export-light .katex-display::-webkit-scrollbar,
      html.scopy-export-light.scopy-scrollbars-visible pre::-webkit-scrollbar,
      html.scopy-export-light.scopy-scrollbars-visible table::-webkit-scrollbar,
      html.scopy-export-light.scopy-scrollbars-visible .katex-display::-webkit-scrollbar {
        width: 0px !important;
        height: 0px !important;
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
                try { window.__scopyHasMath = true; } catch (e) { }
                try { window.__scopyMathRendered = false; } catch (e) { }
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
                  try { window.__scopyMathRendered = true; } catch (e) { }
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
            try { window.__scopyHasMath = false; } catch (e) { }
            try { window.__scopyMathRendered = true; } catch (e) { }
            window.__scopyMarkdownRendered = false;
            window.__scopyTablesFitDone = false;
            function unwrapExportTables(el) {
              try {
                var wraps = el.querySelectorAll('.scopy-table-export-wrap');
                for (var i = 0; i < wraps.length; i++) {
                  var w = wraps[i];
                  if (!w || !w.parentNode) { continue; }
                  var inner = w.querySelector('.scopy-table-export-inner');
                  var t = inner ? inner.querySelector('table') : null;
                  if (t) {
                    w.parentNode.insertBefore(t, w);
                  }
                  try { w.parentNode.removeChild(w); } catch (e) { }
                }
              } catch (e) { }
            }

            function ensureExportTableWrappers(el) {
              var tables = el.querySelectorAll('table');
              if (!tables || tables.length === 0) { return; }
              for (var i = 0; i < tables.length; i++) {
                var t = tables[i];
                if (!t || !t.parentNode) { continue; }
                // Already wrapped
                try {
                  if (t.closest && t.closest('.scopy-table-export-inner')) { continue; }
                } catch (e) { }

                var wrap = document.createElement('div');
                wrap.className = 'scopy-table-export-wrap';
                var inner = document.createElement('div');
                inner.className = 'scopy-table-export-inner';

                t.parentNode.insertBefore(wrap, t);
                wrap.appendChild(inner);
                inner.appendChild(t);
              }
            }

            window.__scopyFitTablesForExport = function () {
              try { window.__scopyTablesFitDone = false; } catch (e) { }

              function fitOnce() {
                var root = document.documentElement;
                if (!root || !root.classList || !root.classList.contains('scopy-export-light')) { return { done: true, changed: false, overflow: false }; }
                var el = document.getElementById('content');
                if (!el) { return { done: true, changed: false, overflow: false }; }

                ensureExportTableWrappers(el);

                // Fit to the actual available content width (exclude padding) so we never clip by 1-2px.
                var containerW = 0;
                try {
                  var rect = el.getBoundingClientRect();
                  var cs = window.getComputedStyle ? window.getComputedStyle(el) : null;
                  var padL = cs ? (parseFloat(cs.paddingLeft || '0') || 0) : 0;
                  var padR = cs ? (parseFloat(cs.paddingRight || '0') || 0) : 0;
                  containerW = (rect.width || 0) - padL - padR;
                } catch (e) { containerW = 0; }
                if (!containerW || containerW <= 0) {
                  containerW = el.clientWidth || 0;
                }
                if (!containerW || containerW <= 0) {
                  return { done: true, changed: false, overflow: false };
                }

                var changed = false;
                var overflow = false;

                // Leave a small safety margin to avoid 1px clipping due to borders / subpixel rounding.
                var safeW = containerW - 8;
                if (safeW < 1) { safeW = 1; }

                var wraps = el.querySelectorAll('.scopy-table-export-wrap');
                for (var i = 0; i < wraps.length; i++) {
                  var wrap = wraps[i];
                  if (!wrap) { continue; }
                  var inner = wrap.querySelector('.scopy-table-export-inner');
                  if (!inner) { continue; }

                  var prev = 1;
                  try { prev = parseFloat(inner.getAttribute('data-scopy-export-scale') || '1') || 1; } catch (e) { prev = 1; }

                  // Reset to measure natural size. (Transforms do not affect scrollWidth/scrollHeight, but this keeps it predictable.)
                  try { inner.style.transform = 'scale(1)'; } catch (e) { }

                  var naturalW = inner.scrollWidth || 0;
                  var naturalH = inner.scrollHeight || 0;
                  if (!naturalW || naturalW <= 0 || !naturalH || naturalH <= 0) { continue; }

                  var scale = 1;
                  if (naturalW > safeW) { scale = safeW / naturalW; }
                  if (scale < 0.20) { scale = 0.20; }
                  if (scale > 1) { scale = 1; }

                  // Apply scale, then verify with boundingClientRect (includes subpixel rounding) and correct if needed.
                  try { inner.style.transform = 'scale(' + scale + ')'; } catch (e) { }
                  var visualW = 0;
                  try { visualW = inner.getBoundingClientRect().width || 0; } catch (e) { visualW = 0; }
                  if (visualW > safeW - 0.5 && visualW > 0) {
                    overflow = true;
                    var factor = (safeW - 2) / visualW;
                    var fixed = scale * factor;
                    if (fixed < 0.20) { fixed = 0.20; }
                    if (fixed > 1) { fixed = 1; }
                    if (Math.abs(fixed - scale) > 0.0005) {
                      scale = fixed;
                      try { inner.style.transform = 'scale(' + scale + ')'; } catch (e) { }
                    }
                    try { visualW = inner.getBoundingClientRect().width || visualW; } catch (e) { }
                  }

                  // Make the wrapper allocate enough height for the transformed inner (transforms don't affect layout).
                  var scaledH = Math.ceil(naturalH * scale + 3);
                  try { wrap.style.height = String(scaledH) + 'px'; } catch (e) { }
                  try { inner.setAttribute('data-scopy-export-scale', String(scale)); } catch (e) { }
                  if (Math.abs(scale - prev) > 0.001) { changed = true; }

                  if (visualW > safeW + 0.5) { overflow = true; }
                }

                return { done: false, changed: changed, overflow: overflow };
              }

              var maxIter = 14;
              var iter = 0;
              function step() {
                try {
                  var r = fitOnce();
                  if (r.done) {
                    if (typeof window.requestAnimationFrame === 'function') {
                      window.requestAnimationFrame(function () { try { window.__scopyTablesFitDone = true; } catch (e) { } });
                    } else {
                      try { window.__scopyTablesFitDone = true; } catch (e) { }
                    }
                    return;
                  }

                  iter += 1;
                  if (iter < maxIter && (r.changed || r.overflow)) {
                    if (typeof window.requestAnimationFrame === 'function') {
                      window.requestAnimationFrame(step);
                    } else {
                      setTimeout(step, 0);
                    }
                    return;
                  }

                  if (typeof window.requestAnimationFrame === 'function') {
                    window.requestAnimationFrame(function () {
                      try { window.__scopyTablesFitDone = true; } catch (e) { }
                      scheduleReportHeight();
                      setTimeout(scheduleReportHeight, 80);
                    });
                  } else {
                    try { window.__scopyTablesFitDone = true; } catch (e) { }
                    scheduleReportHeight();
                    setTimeout(scheduleReportHeight, 80);
                  }
                } catch (e) {
                  try { window.__scopyTablesFitDone = true; } catch (e2) { }
                }
              }

              if (typeof window.requestAnimationFrame === 'function') {
                window.requestAnimationFrame(step);
              } else {
                setTimeout(step, 0);
              }
            };
            window.__scopyExportHasHorizontalOverflow = function () {
              try {
                var root = document.documentElement;
                if (!root || !root.classList || !root.classList.contains('scopy-export-light')) { return false; }
                var el = document.getElementById('content');
                if (!el) { return false; }

                var containerW = 0;
                try {
                  var rect = el.getBoundingClientRect();
                  var cs = window.getComputedStyle ? window.getComputedStyle(el) : null;
                  var padL = cs ? (parseFloat(cs.paddingLeft || '0') || 0) : 0;
                  var padR = cs ? (parseFloat(cs.paddingRight || '0') || 0) : 0;
                  containerW = (rect.width || 0) - padL - padR;
                } catch (e) { containerW = 0; }
                if (!containerW || containerW <= 0) { containerW = el.clientWidth || 0; }
                if (!containerW || containerW <= 0) { return false; }

                var safeW = containerW - 8;
                if (safeW < 1) { safeW = 1; }
                var wraps = el.querySelectorAll('.scopy-table-export-wrap');
                for (var i = 0; i < wraps.length; i++) {
                  var inner = wraps[i] ? wraps[i].querySelector('.scopy-table-export-inner') : null;
                  if (!inner) { continue; }
                  var w = 0;
                  try { w = inner.getBoundingClientRect().width || 0; } catch (e) { w = 0; }
                  if (w > safeW + 0.5) { return true; }
                }
                return false;
              } catch (e) { return false; }
            };
            window.__scopySetExportMode = function (enabled) {
              try {
                var root = document.documentElement;
                if (!root) { return; }
                if (enabled) {
                  root.classList.add('scopy-export-light');
                  root.classList.remove('scopy-scrollbars-visible');
                  if (typeof window.__scopyFitTablesForExport === 'function') {
                    setTimeout(function () { try { window.__scopyFitTablesForExport(); } catch (e) { } }, 0);
                  }
                } else {
                  root.classList.remove('scopy-export-light');
                  try {
                    var el = document.getElementById('content');
                    if (el) {
                      unwrapExportTables(el);
                    }
                  } catch (e) { }
                }
              } catch (e) { }
            };
            window.__scopyReportHeight = function () {
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
                if (Math.abs(h - lastH) < 1 && Math.abs(w - lastW) < 1) { return; }
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
              // `scroll` doesn't bubble; capture phase catches it from overflow containers (pre/table/katex-display).
              try { document.addEventListener('scroll', function () { showScrollbarsTemporarily(); }, true); } catch (e) { }
              try { document.addEventListener('wheel', function () { showScrollbarsTemporarily(); }, { passive: true }); } catch (e) { }

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
              try { window.__scopyMarkdownRendered = true; } catch (e) { }
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
