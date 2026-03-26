import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let featureSet = MarkdownRenderFeatureSet.scopyDefault
        guard !Task.isCancelled else { return "" }
        let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
        guard !Task.isCancelled else { return "" }
        let normalizedMarkdown = MathNormalizer.wrapLooseLaTeX(latexNormalized)
        guard !Task.isCancelled else { return "" }
        let protected = MathProtector.protectMath(in: normalizedMarkdown)
        guard !Task.isCancelled else { return "" }
        let inlineNormalizedMarkdown = LaTeXInlineTextNormalizer.normalize(protected.markdown)
        let normalizedHeadingsMarkdown = normalizeATXHeadings(in: inlineNormalizedMarkdown)
        let safeHTMLExtraction = featureSet.safeHTMLSubset
            ? MarkdownSafeHTMLSubset.extract(from: normalizedHeadingsMarkdown)
            : MarkdownSafeHTMLExtractionResult(
                markdown: normalizedHeadingsMarkdown,
                fallbackMarkdown: normalizedHeadingsMarkdown,
                replacements: [:]
            )
        let renderMarkdown = safeHTMLExtraction.markdown
        let hasMath = MarkdownDetector.containsMath(normalizedMarkdown)
        let enableMath = featureSet.math && hasMath

        let fallbackText = MathProtector.restoreMath(
            in: safeHTMLExtraction.fallbackMarkdown,
            placeholders: protected.placeholders,
            escape: { $0 }
        )

        guard !Task.isCancelled else { return "" }
        return htmlDocument(
            featureSet: featureSet,
            markdown: renderMarkdown,
            placeholders: protected.placeholders,
            safeHTMLReplacements: safeHTMLExtraction.replacements,
            enableMath: enableMath,
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

    private static func baseStyle(featureSet: MarkdownRenderFeatureSet) -> String {
        let taskListStyle = featureSet.taskLists ? "\n\(MarkdownTaskListRuntime.style)\n" : ""
        let footnoteStyle = featureSet.footnotes ? """
          .footnotes {
            margin-top: 1.5rem;
            padding-top: 1rem;
            border-top: 1px solid rgba(127,127,127,0.25);
          }
          .footnotes-list {
            padding-left: 1.5rem;
          }
          .footnotes p:first-child {
            margin-top: 0;
          }
          .footnotes p:last-child {
            margin-bottom: 0;
          }
          sup.footnote-ref {
            display: inline-block;
            margin-left: 0.12em;
            vertical-align: super;
            line-height: 0;
          }
          .footnote-ref a,
          .footnote-backref {
            display: inline-block;
            font-size: 0.74em;
            color: #2563eb;
            font-weight: 700;
            text-decoration: none;
          }
          .footnote-ref a {
            min-width: 1.15em;
            padding: 0.08em 0.26em;
            border-radius: 999px;
            background: rgba(37, 99, 235, 0.14);
            box-shadow: inset 0 0 0 1px rgba(37, 99, 235, 0.14);
          }
          .footnote-ref a:hover,
          .footnote-ref a:focus,
          .footnote-backref:hover,
          .footnote-backref:focus {
            color: color-mix(in srgb, var(--scopy-link) 82%, #071a36 18%);
            text-decoration: underline;
          }
        """ : ""
        let definitionListStyle = featureSet.definitionLists ? """
          dl {
            display: grid;
            grid-template-columns: minmax(7rem, max-content) minmax(0, 1fr);
            column-gap: 1rem;
            row-gap: 0.5rem;
          }
          dt {
            font-weight: 600;
          }
          dd {
            margin: 0;
          }
        """ : ""
        let safeHTMLStyle = featureSet.safeHTMLSubset ? """
          details {
            margin: 0 0 1rem 0;
            padding: 0.75rem 0.875rem;
            border: 1px solid rgba(127,127,127,0.22);
            border-radius: 12px;
            background: rgba(127,127,127,0.05);
          }
          details[open] {
            padding-bottom: 0.875rem;
          }
          details > *:last-child {
            margin-bottom: 0;
          }
          summary {
            cursor: default;
            font-weight: 600;
          }
          kbd {
            display: inline-block;
            min-width: 1.5em;
            padding: 0.08em 0.45em;
            border: 1px solid rgba(127,127,127,0.32);
            border-bottom-width: 2px;
            border-radius: 6px;
            background: rgba(127,127,127,0.08);
            box-shadow: inset 0 -1px 0 rgba(127,127,127,0.15);
            font: 0.92em ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          }
          mark {
            color: inherit;
            background: rgba(255, 225, 92, 0.55);
            border-radius: 0.2em;
            padding: 0 0.2em;
          }
          u {
            text-underline-offset: 0.16em;
          }
          sub,
          sup {
            font-size: 0.72em;
          }
        """ : ""

        return """
        <style>
          :root {
            color-scheme: light;
            --scopy-page-bg: #eef2f7;
            --scopy-surface-bg: #ffffff;
            --scopy-surface-border: rgba(15, 23, 42, 0.09);
            --scopy-surface-shadow: 0 14px 38px rgba(15, 23, 42, 0.08);
            --scopy-text-primary: #0f172a;
            --scopy-text-secondary: rgba(15, 23, 42, 0.72);
            --scopy-code-bg: #f6f8fb;
            --scopy-inline-code-bg: #e9eef5;
            --scopy-link: #0a66d9;
          }
          body {
            margin: 0;
            padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
            font-size: 15px;
            line-height: 1.65;
            color: var(--scopy-text-primary);
            background: var(--scopy-page-bg);
          }
          html, body {
            overflow-x: hidden;
            min-height: 100%;
          }
          * { box-sizing: border-box; }
          #content {
            padding: 20px 18px;
            display: block;
            max-width: 100%;
            box-sizing: border-box;
            word-break: break-word;
            color: var(--scopy-text-primary);
            background: var(--scopy-surface-bg);
            border: 1px solid var(--scopy-surface-border);
            border-radius: 18px;
            box-shadow: var(--scopy-surface-shadow);
            opacity: 0;
            transition: opacity 140ms ease-in-out;
          }
          p,
          ul,
          ol,
          blockquote,
          pre,
          table,
          dl,
          details {
            margin: 0 0 1rem 0;
          }
          h1, h2, h3, h4, h5, h6 {
            line-height: 1.25;
            font-weight: 700;
            margin: 1.5rem 0 0.8rem 0;
          }
          h1 {
            font-size: 1.85rem;
            padding-bottom: 0.3rem;
            border-bottom: 1px solid rgba(127,127,127,0.22);
          }
          h2 {
            font-size: 1.5rem;
            padding-bottom: 0.22rem;
            border-bottom: 1px solid rgba(127,127,127,0.18);
          }
          h3 { font-size: 1.28rem; }
          h4 { font-size: 1.12rem; }
          h5 { font-size: 1rem; }
          h6 { font-size: 0.92rem; color: var(--scopy-text-secondary); }
          h1:first-child,
          h2:first-child,
          h3:first-child,
          h4:first-child,
          h5:first-child,
          h6:first-child {
            margin-top: 0;
          }
          ul, ol {
            padding-left: 1.55rem;
          }
          li + li {
            margin-top: 0.28rem;
          }
          li > ul,
          li > ol {
            margin-top: 0.38rem;
          }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
          code {
            font-size: 0.92em;
          }
          :not(pre) > code {
            padding: 0.15em 0.35em;
            border-radius: 6px;
            background: var(--scopy-inline-code-bg);
          }
          pre {
            padding: 14px 16px;
            border-radius: 12px;
            border: 1px solid rgba(15, 23, 42, 0.08);
            overflow-x: auto;
            max-width: 100%;
            box-sizing: border-box;
            color: var(--scopy-text-primary);
            background: var(--scopy-code-bg);
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.68);
          }
          pre code {
            display: block;
            padding: 0;
            background: transparent;
            white-space: pre;
            word-break: normal;
            overflow-wrap: normal;
            min-width: max-content;
            line-height: 1.55;
          }
          .hljs {
            background: transparent;
          }
          .hljs-doctag,
          .hljs-keyword,
          .hljs-meta .hljs-keyword,
          .hljs-template-tag,
          .hljs-template-variable,
          .hljs-type,
          .hljs-variable.language_ {
            color: #d73a49;
          }
          .hljs-title,
          .hljs-title.class_,
          .hljs-title.class_.inherited__,
          .hljs-title.function_ {
            color: #6f42c1;
          }
          .hljs-attr,
          .hljs-attribute,
          .hljs-literal,
          .hljs-meta,
          .hljs-number,
          .hljs-operator,
          .hljs-selector-attr,
          .hljs-selector-class,
          .hljs-selector-id,
          .hljs-variable,
          .hljs-section {
            color: #005cc5;
          }
          .hljs-meta .hljs-string,
          .hljs-regexp,
          .hljs-string {
            color: #032f62;
          }
          .hljs-built_in,
          .hljs-symbol {
            color: #e36209;
          }
          .hljs-code,
          .hljs-comment,
          .hljs-formula {
            color: #6a737d;
          }
          .hljs-name,
          .hljs-quote,
          .hljs-selector-pseudo,
          .hljs-selector-tag,
          .hljs-addition {
            color: #22863a;
          }
          .hljs-subst,
          .hljs-emphasis,
          .hljs-strong {
            color: #24292e;
          }
          .hljs-bullet {
            color: #735c0f;
          }
          .hljs-emphasis {
            font-style: italic;
          }
          .hljs-strong,
          .hljs-section {
            font-weight: 700;
          }
          .hljs-addition {
            background-color: #f0fff4;
          }
          .hljs-deletion {
            color: #b31d28;
            background-color: #ffeef0;
          }
          html.scopy-export-mode #content {
            box-shadow: none;
          }
          html.scopy-export-mode pre.scopy-export-wrap-code {
            overflow: visible;
          }
          html.scopy-export-mode pre.scopy-export-wrap-code code {
            white-space: pre-wrap;
            word-break: break-word;
            overflow-wrap: anywhere;
            min-width: 0;
          }
          img { max-width: 100%; height: auto; }
          a {
            pointer-events: none;
            color: var(--scopy-link);
            text-decoration: underline;
            text-underline-offset: 0.14em;
          }
          blockquote {
            margin: 0 0 1rem 0;
            padding: 0.18rem 0 0.18rem 1rem;
            border-left: 4px solid rgba(127,127,127,0.34);
            color: var(--scopy-text-secondary);
          }
          blockquote > :last-child {
            margin-bottom: 0;
          }
          hr { border: 0; border-top: 1px solid rgba(127,127,127,0.35); margin: 1.2rem 0; }
          .katex-display {
            max-width: 100%;
            overflow-x: auto;
            overflow-y: hidden;
            margin: 1rem 0;
          }
          table {
            display: block;
            border-collapse: collapse;
            max-width: 100%;
            overflow-x: auto;
            width: 100%;
            table-layout: auto;
            border-spacing: 0;
          }
          th, td {
            border: 1px solid rgba(127,127,127,0.25);
            padding: 8px 10px;
            vertical-align: top;
            white-space: normal;
            word-break: break-word;
            overflow-wrap: anywhere;
          }
          thead th {
            background: rgba(15, 23, 42, 0.06);
            font-weight: 600;
          }
          \(taskListStyle)\(footnoteStyle)\(definitionListStyle)\(safeHTMLStyle)
          /* Hide scrollbars inside HTML when idle (even if system setting is "always show scroll bars").
             We show them temporarily while the user is actively scrolling overflow containers (JS toggles the class). */
          pre::-webkit-scrollbar,
          table::-webkit-scrollbar,
          .katex-display::-webkit-scrollbar,
          .footnotes::-webkit-scrollbar,
          details::-webkit-scrollbar {
            width: 0px;
            height: 0px;
          }
          html.scopy-scrollbars-visible pre::-webkit-scrollbar,
          html.scopy-scrollbars-visible table::-webkit-scrollbar,
          html.scopy-scrollbars-visible .katex-display::-webkit-scrollbar,
          html.scopy-scrollbars-visible .footnotes::-webkit-scrollbar,
          html.scopy-scrollbars-visible details::-webkit-scrollbar {
            width: 8px;
            height: 8px;
          }
        </style>
        """
    }

    private static func htmlDocument(
        featureSet: MarkdownRenderFeatureSet,
        markdown: String,
        placeholders: [(placeholder: String, original: String)],
        safeHTMLReplacements: [String: MarkdownSafeHTMLSubset.Replacement],
        enableMath: Bool,
        fallbackText: String
    ) -> String {
        let mathIncludes: String
        if featureSet.math && enableMath {
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
        let placeholdersLiteral = jsonLiteral(placeholderMap)
        let overflowSelectorLiteral = jsonStringLiteral(featureSet.overflowProbeSelector)
        let safeHTMLLiteral = jsonLiteral(safeHTMLReplacements)
        let taskListBootstrapScript = featureSet.taskLists ? MarkdownTaskListRuntime.bootstrapScript : ""
        let footnotesReadyCheck = featureSet.footnotes ? """
              if (typeof window.markdownitFootnote !== 'function') {
                setTimeout(renderMarkdown, 30);
                return;
              }
""" : ""
        let definitionListReadyCheck = featureSet.definitionLists ? """
              if (typeof window.markdownitDeflist !== 'function') {
                setTimeout(renderMarkdown, 30);
                return;
              }
""" : ""
        let highlightReadyCheck = featureSet.codeHighlighting ? """
              if (typeof window.hljs !== 'object') {
                setTimeout(renderMarkdown, 30);
                return;
              }
""" : ""
        let footnotesInstallScript = featureSet.footnotes ? """
              if (md && typeof md.use === 'function' && typeof window.markdownitFootnote === 'function') {
                md.use(window.markdownitFootnote);
                if (md.renderer && md.renderer.rules) {
                  md.renderer.rules.footnote_caption = function (tokens, idx) {
                    try {
                      var n = Number(tokens[idx].meta.id + 1).toString();
                      if (tokens[idx].meta.subId > 0) { n += ':' + String(tokens[idx].meta.subId); }
                      return n;
                    } catch (e) {
                      return '';
                    }
                  };
                }
              }
""" : ""
        let definitionListInstallScript = featureSet.definitionLists ? """
              if (md && typeof md.use === 'function' && typeof window.markdownitDeflist === 'function') {
                md.use(window.markdownitDeflist);
              }
""" : ""
        let taskListApplyScript = featureSet.taskLists ? """
              if (typeof window.__scopyApplyTaskLists === 'function') {
                window.__scopyApplyTaskLists(el);
              }
""" : ""
        let highlightOptionsScript = featureSet.codeHighlighting ? """
              mdOptions.highlight = function (str, lang) {
                if (typeof window.hljs !== 'object') { return ''; }
                try {
                  if (lang && typeof window.hljs.getLanguage === 'function' && window.hljs.getLanguage(lang)) {
                    return window.hljs.highlight(str, { language: lang, ignoreIllegals: true }).value;
                  }
                  return window.hljs.highlightAuto(str).value;
                } catch (e) {
                  return '';
                }
              };
""" : ""
        let highlightFinalizeScript = featureSet.codeHighlighting ? """
              try {
                var codeBlocks = el.querySelectorAll('pre code');
                for (var i = 0; i < codeBlocks.length; i++) {
                  var codeEl = codeBlocks[i];
                  codeEl.classList.add('hljs');
                  if (codeEl.parentElement) {
                    codeEl.parentElement.classList.add('hljs');
                  }
                }
              } catch (e) { }
""" : ""

        let markdownRenderScript = """
        \(featureSet.markdownAssetHeadTags)
        \(taskListBootstrapScript)
        <script>
          (function () {
            var lastH = 0;
            var lastW = 0;
            var pendingRAF = false;
            var ro = null;
            window.__scopyRenderState = window.__scopyRenderState || {
              renderComplete: false,
              markdownRendered: false,
              highlightThemeReady: false,
              requiresHighlightTheme: false,
              renderPass: 0
            };
            function hasLoadedStylesheet(fragment) {
              try {
                if (!document || typeof document.querySelectorAll !== 'function') { return false; }
                var links = document.querySelectorAll('link[rel="stylesheet"]');
                for (var i = 0; i < links.length; i++) {
                  var link = links[i];
                  if (!link) { continue; }
                  var href = '';
                  try { href = String(link.getAttribute('href') || ''); } catch (e) { href = ''; }
                  if (fragment && href.indexOf(fragment) === -1) { continue; }
                  try {
                    if (link.sheet) { return true; }
                  } catch (e) { }
                }
              } catch (e) { }
              return false;
            }
            window.__scopyIsRenderReady = function () {
              try {
                var state = window.__scopyRenderState || {};
                return !!state.renderComplete && !!state.markdownRendered;
              } catch (e) {
                return false;
              }
            };
            function updateHighlightThemeReady() {
              try {
                if (!window.__scopyRenderState) { return false; }
                var requiresHighlightTheme = !!window.__scopyRenderState.requiresHighlightTheme;
                var ready = !requiresHighlightTheme || hasLoadedStylesheet('highlight-github.min.css');
                window.__scopyRenderState.highlightThemeReady = ready;
                return ready;
              } catch (e) {
                return false;
              }
            }
            function finalizeRenderState(remainingPolls) {
              try {
                if (!window.__scopyRenderState) { return; }
                var state = window.__scopyRenderState;
                if (!state.markdownRendered) { return; }
                if (!!state.requiresHighlightTheme && !updateHighlightThemeReady() && remainingPolls > 0) {
                  setTimeout(function () { finalizeRenderState(remainingPolls - 1); }, 30);
                  return;
                }
                state.renderComplete = true;
              } catch (e) { }
              scheduleReportHeight();
            }
            function normalizeFootnoteReferences(root) {
              try {
                if (!root || typeof root.querySelectorAll !== 'function') { return; }
                var refs = root.querySelectorAll('sup.footnote-ref > a');
                for (var i = 0; i < refs.length; i++) {
                  var ref = refs[i];
                  if (!ref) { continue; }
                  var text = '';
                  try { text = String(ref.textContent || ''); } catch (e) { text = ''; }
                  var match = text.match(/^\\[(.+)\\]$/);
                  if (match && match[1]) {
                    try { ref.textContent = match[1]; } catch (e) { }
                  }
                }
              } catch (e) { }
            }
            var safeHTMLMap = \(safeHTMLLiteral);
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
                  var nodes = el.querySelectorAll(\(overflowSelectorLiteral));
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
              try {
                if (window.__scopyRenderState) {
                  window.__scopyRenderState.renderComplete = false;
                  window.__scopyRenderState.markdownRendered = false;
                  window.__scopyRenderState.highlightThemeReady = false;
                  window.__scopyRenderState.requiresHighlightTheme = false;
                  window.__scopyRenderState.renderPass = (window.__scopyRenderState.renderPass || 0) + 1;
                }
              } catch (e) { }
              if (typeof window.markdownit !== 'function') {
                setTimeout(renderMarkdown, 30);
                return;
              }
              \(footnotesReadyCheck)\(definitionListReadyCheck)\(highlightReadyCheck)
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
                  if (t.matches && t.matches(\(overflowSelectorLiteral))) { return true; }
                  if (t.closest && t.closest(\(overflowSelectorLiteral))) { return true; }
                } catch (e) { }
                return false;
              }
              // `scroll` doesn't bubble; capture phase catches it from overflow containers.
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
              function escapeHTMLText(text) {
                return String(text || '')
                  .replace(/&/g, '&amp;')
                  .replace(/</g, '&lt;')
                  .replace(/>/g, '&gt;')
                  .replace(/"/g, '&quot;');
              }
              function applySafeHTMLReplacements(html, md) {
                if (!html) { return html; }
                function renderSafeHTMLToken(token) {
                  var item = safeHTMLMap[token];
                  if (!item) { return token; }
                  if (item.kind === 'inlineTag') {
                    var tag = item.tag || 'span';
                    return '<' + tag + '>' + escapeHTMLText(item.text || '') + '</' + tag + '>';
                  }
                  if (item.kind === 'details') {
                    var summaryHTML = item.summary ? applySafeHTMLReplacements(md.renderInline(item.summary), md) : '';
                    var bodyHTML = item.body ? applySafeHTMLReplacements(md.render(item.body), md) : '';
                    return '<details class="scopy-details"' + (item.isOpen ? ' open' : '') + '><summary>' + summaryHTML + '</summary>' + bodyHTML + '</details>';
                  }
                  return token;
                }

                html = html.replace(/<p>\\s*(SCOPYSAFEHTMLPLACEHOLDER\\d+X)\\s*<\\/p>/g, function (_, token) {
                  return renderSafeHTMLToken(token);
                });
                return html.replace(/SCOPYSAFEHTMLPLACEHOLDER\\d+X/g, function (token) {
                  return renderSafeHTMLToken(token);
                });
              }

              var mdOptions = \(featureSet.markdownItOptionsJSLiteral);
              \(highlightOptionsScript)
              var md = window.markdownit(mdOptions);
              \(footnotesInstallScript)\(definitionListInstallScript)
              if (md && typeof md.enable === 'function') {
                \(featureSet.markdownItEnableStatementsJS)
              }
              var src = \(markdownLiteral);
              var html = md.render(src);
              var map = \(placeholdersLiteral);
              html = html.replace(/SCOPYMATHPLACEHOLDER\\d+X/g, function (m) { return map[m] || m; });
              html = applySafeHTMLReplacements(html, md);
              el.innerHTML = html;
              normalizeFootnoteReferences(el);
              \(taskListApplyScript)\(highlightFinalizeScript)
              try {
                if (window.__scopyRenderState) {
                  window.__scopyRenderState.requiresHighlightTheme = \(featureSet.codeHighlighting ? "true" : "false") && !!el.querySelector('pre code');
                }
              } catch (e) { }

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
              try {
                if (window.__scopyRenderState) {
                  window.__scopyRenderState.markdownRendered = true;
                }
              } catch (e) { }
              scheduleReportHeight();
              setTimeout(scheduleReportHeight, 120);
              setTimeout(function () {
                finalizeRenderState(50);
              }, 30);
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
            \(baseStyle(featureSet: featureSet))
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
        jsonLiteral(value)
    }

    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return s.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }
}
