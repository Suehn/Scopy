import Foundation
import ScopyKit

enum MarkdownHTMLDocumentBuilder {
    private static let layout = MarkdownRenderLayoutConstants.self

    private static let cspMetaTag = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline' file:; script-src 'self' 'unsafe-inline' file:; font-src 'self' data: file:;">
    """

    private static let tableWrapFunctionScript = """
            function readChatGPTTableColumnCount(table) {
              try {
                var row = table && table.querySelector && table.querySelector('tr');
                if (!row || !row.children) { return 0; }
                return row.children.length || 0;
              } catch (e) {
                return 0;
              }
            }
            function readChatGPTTableColumnLengths(table, columns) {
              var lengths = [];
              for (var i = 0; i < columns; i++) { lengths.push(0); }
              try {
                var rows = table.querySelectorAll('tr');
                for (var r = 0; r < (rows.length || 0); r++) {
                  var cells = rows[r] && rows[r].children;
                  if (!cells) { continue; }
                  for (var c = 0; c < cells.length && c < columns; c++) {
                    var text = '';
                    try { text = String(cells[c].textContent || '').replace(/\\s+/g, ' ').trim(); } catch (e) { text = ''; }
                    lengths[c] = Math.max(lengths[c] || 0, text.length || 0);
                  }
                }
              } catch (e) { }
              return lengths;
            }
            function chatGPTWideTableColumnSize(length) {
              if (length <= 18) { return 'sm'; }
              if (length <= 40) { return 'md'; }
              if (length <= 80) { return 'lg'; }
              return 'xl';
            }
            function classifyChatGPTTable(wrapper, table) {
              try {
                if (!wrapper || !table || !table.querySelectorAll) { return; }
                var columns = readChatGPTTableColumnCount(table);
                var lengths = readChatGPTTableColumnLengths(table, columns);
                var totalLength = 0;
                var maxLength = 0;
                for (var i = 0; i < lengths.length; i++) {
                  totalLength += lengths[i] || 0;
                  maxLength = Math.max(maxLength, lengths[i] || 0);
                }
                var measuredOverflow = false;
                try {
                  var available = Math.ceil(wrapper.clientWidth || 0);
                  var raw = measureChatGPTTableWidth(table);
                  measuredOverflow = !!(available && raw && raw > available + 1);
                } catch (e) { measuredOverflow = false; }
                var isWide = !!(
                  columns >= 4 ||
                  (columns >= 3 && (maxLength >= 40 || totalLength >= 96)) ||
                  measuredOverflow
                );
                if (isWide) {
                  wrapper.classList.add('scopy-chatgpt-wide-table');
                  table.classList.add('scopy-chatgpt-wide-table');
                } else {
                  wrapper.classList.remove('scopy-chatgpt-wide-table');
                  table.classList.remove('scopy-chatgpt-wide-table');
                }
                var rows = table.querySelectorAll('tr');
                for (var r = 0; r < (rows.length || 0); r++) {
                  var cells = rows[r] && rows[r].children;
                  if (!cells) { continue; }
                  for (var c = 0; c < cells.length; c++) {
                    if (isWide && c < lengths.length) {
                      cells[c].setAttribute('data-scopy-col-size', chatGPTWideTableColumnSize(lengths[c] || 0));
                    } else {
                      cells[c].removeAttribute('data-scopy-col-size');
                    }
                  }
                }
              } catch (e) { }
            }
            function wrapChatGPTTables(root) {
              try {
                if (!root || typeof root.querySelectorAll !== 'function') { return; }
                var tables = root.querySelectorAll('table');
                for (var i = 0; i < (tables.length || 0); i++) {
                  var table = tables[i];
                  if (!table || !table.parentNode) { continue; }
                  var parent = table.parentElement;
                  if (parent && parent.classList && parent.classList.contains('scopy-chatgpt-table-container')) {
                    classifyChatGPTTable(parent, table);
                    continue;
                  }
                  var wrapper = document.createElement('div');
                  wrapper.className = 'scopy-chatgpt-table-container';
                  table.parentNode.insertBefore(wrapper, table);
                  wrapper.appendChild(table);
                  classifyChatGPTTable(wrapper, table);
                }
              } catch (e) { }
            }
            function resetChatGPTTableScale(container, table) {
              try {
                if (table && table.style && table.dataset && table.dataset.scopyTableScaled === 'true') {
                  table.style.transform = '';
                  table.style.transformOrigin = '';
                  delete table.dataset.scopyTableScaled;
                }
                if (container && container.style && container.dataset && container.dataset.scopyTableScaled === 'true') {
                  container.style.height = '';
                  container.style.overflowX = '';
                  delete container.dataset.scopyTableScaled;
                }
              } catch (e) { }
            }
            function measureChatGPTTableWidth(node) {
              if (!node) { return 0; }
              try { void node.offsetHeight; } catch (e) { }
              var rectW = 0, scrollW = 0, offsetW = 0, clientW = 0;
              try { rectW = Math.ceil(node.getBoundingClientRect().width || 0); } catch (e) { rectW = 0; }
              try { scrollW = Math.ceil(node.scrollWidth || 0); } catch (e) { scrollW = 0; }
              try { offsetW = Math.ceil(node.offsetWidth || 0); } catch (e) { offsetW = 0; }
              try { clientW = Math.ceil(node.clientWidth || 0); } catch (e) { clientW = 0; }
              return Math.max(rectW, scrollW, offsetW, clientW);
            }
            function readCSSPixelVariable(root, name, fallback) {
              try {
                var raw = window.getComputedStyle(root).getPropertyValue(name);
                var value = parseFloat(raw);
                if (value && isFinite(value) && value > 0) { return value; }
              } catch (e) { }
              return fallback;
            }
            function currentChatGPTPreviewScale() {
              try {
                var root = document.documentElement;
                var raw = window.getComputedStyle(root).getPropertyValue('--scopy-chatgpt-preview-scale');
                var value = parseFloat(raw);
                if (value && isFinite(value) && value > 0) { return value; }
              } catch (e) { }
              return 1;
            }
            function updateChatGPTPreviewScale(content) {
              try {
                var root = document.documentElement;
                if (!root || !content) { return 1; }
                var shell = document.getElementById('content-scale-shell');
                var renderWidth = readCSSPixelVariable(root, '--scopy-chatgpt-render-width', 816);
                var isExport = !!(root.classList && root.classList.contains('scopy-export-mode'));
                var scale = 1;
                if (!isExport) {
                  var available = 0;
                  try { available = Math.floor(window.innerWidth || document.documentElement.clientWidth || renderWidth); } catch (e) { available = renderWidth; }
                  if (available && isFinite(available) && available > 0) {
                    scale = Math.max(0.01, Math.min(1, available / renderWidth));
                  }
                }
                root.style.setProperty('--scopy-chatgpt-preview-scale', String(scale));
                if (shell && shell.style) {
                  if (isExport) {
                    shell.style.width = renderWidth + 'px';
                    shell.style.maxWidth = 'none';
                    shell.style.height = '';
                  } else {
                    shell.style.width = Math.ceil(renderWidth * scale) + 'px';
                    shell.style.maxWidth = '100%';
                    var rawHeight = 0;
                    try { rawHeight = Math.ceil(content.offsetHeight || content.scrollHeight || 0); } catch (e) { rawHeight = 0; }
                    if (rawHeight && rawHeight > 0) {
                      shell.style.height = Math.ceil(rawHeight * scale + 1) + 'px';
                    }
                  }
                }
                return scale;
              } catch (e) {
                return 1;
              }
            }
            function scaleChatGPTTables(root, explicitTargetWidth) {
              try {
                if (!root || typeof root.querySelectorAll !== 'function') { return; }
                wrapChatGPTTables(root);
                var shouldScale = false;
                var targetWidth = Number(explicitTargetWidth || 0);
                if (targetWidth && isFinite(targetWidth) && targetWidth > 0) {
                  shouldScale = true;
                }
                var containers = root.querySelectorAll('.scopy-chatgpt-table-container');
                for (var i = 0; i < (containers.length || 0); i++) {
                  var container = containers[i];
                  if (!container) { continue; }
                  var table = container.querySelector('table');
                  if (!table) { continue; }
                  resetChatGPTTableScale(container, table);
                  if (!shouldScale) { continue; }
                  var available = targetWidth;
                  if (!available || !isFinite(available) || available <= 0) { continue; }
                  var rawWidth = measureChatGPTTableWidth(table);
                  if (!rawWidth || rawWidth <= available + 1) { continue; }
                  var scale = Math.max(0.01, Math.min(1, (available - 1) / rawWidth));
                  if (!scale || !isFinite(scale) || scale >= 0.999) { continue; }
                  var rawHeight = 0;
                  try { rawHeight = Math.ceil(table.offsetHeight || table.scrollHeight || table.getBoundingClientRect().height || 0); } catch (e) { rawHeight = 0; }
                  try {
                    table.style.transform = 'scale(' + scale + ')';
                    table.style.transformOrigin = 'top left';
                    table.dataset.scopyTableScaled = 'true';
                    container.style.overflowX = 'visible';
                    container.dataset.scopyTableScaled = 'true';
                    if (rawHeight && rawHeight > 0) {
                      container.style.height = Math.ceil(rawHeight * scale + 1) + 'px';
                    }
                  } catch (e) { }
                }
              } catch (e) { }
            }
            try { window.__scopyScaleChatGPTTables = scaleChatGPTTables; } catch (e) { }
    """

    private static func baseStyle(featureSet: MarkdownRenderFeatureSet) -> String {
        let taskListStyle = featureSet.taskLists ? "\n\(MarkdownTaskListRuntime.style)\n" : ""
        let footnoteStyle = featureSet.footnotes ? """
          .footnotes {
            margin-top: 16px;
            padding-top: 0;
            border-top: 0;
            font-size: 16px;
            line-height: 26px;
          }
          .footnotes-list {
            margin: 0;
            padding-left: 26px;
          }
          .footnotes p:first-child {
            margin-top: 0;
          }
          .footnotes p:last-child {
            margin-bottom: 0;
          }
          sup.footnote-ref {
            display: inline-flex;
            position: static;
            top: auto;
            margin-left: 4px;
            font-size: 12px;
            line-height: 20px;
            font-weight: 500;
            vertical-align: baseline;
          }
          sup:has(> a[data-footnote-ref]) {
            display: inline-flex;
            position: static;
            top: auto;
            margin-left: 4px;
            font-size: 12px;
            line-height: 20px;
            font-weight: 500;
            vertical-align: baseline;
          }
          .footnote-ref a,
          a[data-footnote-ref],
          .footnote-backref {
            color: rgb(95, 95, 95);
            font-weight: 500;
            text-decoration: none;
          }
          .footnote-ref a,
          a[data-footnote-ref] {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            min-width: 0;
            height: 25px;
            min-height: 25px;
            padding: 0 8px;
            border-radius: 999px;
            background: rgba(13, 13, 13, 0.04);
            box-shadow: none;
            white-space: nowrap;
          }
          .footnote-ref a::after,
          a[data-footnote-ref]::after,
          .footnote-backref::after,
          [data-footnote-backref]::after {
            content: none;
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
            --scopy-chatgpt-font: -apple-system-body, ui-sans-serif, -apple-system, "system-ui", "Segoe UI", Helvetica, "Apple Color Emoji", Arial, "sans-serif", "Segoe UI Emoji", "Segoe UI Symbol";
            --scopy-chatgpt-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
            --scopy-text-primary: rgb(13, 13, 13);
            --scopy-page-bg: #ffffff;
            --scopy-code-bg: rgba(13, 13, 13, 0.04);
            --scopy-code-border: rgba(13, 13, 13, 0.08);
            --scopy-code-card-bg: rgb(249, 249, 249);
            --scopy-code-card-border: rgba(13, 13, 13, 0.05);
            --scopy-border: rgba(13, 13, 13, 0.15);
            --scopy-border-subtle: rgba(13, 13, 13, 0.10);
            --scopy-text-secondary: rgb(93, 93, 93);
            --scopy-syntax-base: #383a42;
            --scopy-syntax-comment: #a0a1a7;
            --scopy-syntax-keyword: #a626a4;
            --scopy-syntax-name: #e45649;
            --scopy-syntax-literal: #0184bb;
            --scopy-syntax-string: #50a14f;
            --scopy-syntax-built-in: #c18401;
            --scopy-syntax-number: #986801;
            --scopy-syntax-symbol: #4078f2;
            --scopy-chatgpt-thread-content-width: \(Self.layout.chatGPTThreadContentWidth)px;
            --scopy-chatgpt-content-inline-padding: \(Self.layout.chatGPTContentInlinePadding)px;
            --scopy-chatgpt-content-top-padding: \(Self.layout.chatGPTContentTopPadding)px;
            --scopy-chatgpt-content-bottom-padding: \(Self.layout.chatGPTContentBottomPadding)px;
            --scopy-chatgpt-render-width: calc(var(--scopy-chatgpt-thread-content-width) + (var(--scopy-chatgpt-content-inline-padding) * 2));
            --scopy-chatgpt-table-breakout-width: var(--scopy-chatgpt-thread-content-width);
            --scopy-chatgpt-preview-scale: 1;
          }
          body {
            margin: 0;
            padding: 0;
            font-family: var(--scopy-chatgpt-font);
            font-size: 16px;
            line-height: 26px;
            font-weight: 400;
            color: var(--scopy-text-primary);
            background: var(--scopy-page-bg);
          }
          html, body {
            overflow-x: hidden;
            min-height: 100%;
          }
          * { box-sizing: border-box; }
          #content-scale-shell {
            display: block;
            width: 100%;
            max-width: 100%;
            margin: 0;
            padding: 0;
            overflow: visible;
          }
          #content {
            display: block;
            width: var(--scopy-chatgpt-render-width);
            max-width: none;
            padding: var(--scopy-chatgpt-content-top-padding) var(--scopy-chatgpt-content-inline-padding) var(--scopy-chatgpt-content-bottom-padding) var(--scopy-chatgpt-content-inline-padding);
            box-sizing: border-box;
            overflow-wrap: break-word;
            word-break: normal;
            color: var(--scopy-text-primary);
            background: var(--scopy-page-bg);
            border: 0;
            border-radius: 0;
            box-shadow: none;
            opacity: 0;
            transition: opacity 140ms ease-in-out;
            transform: scale(var(--scopy-chatgpt-preview-scale));
            transform-origin: top left;
          }
          h1, h2, h3, h4, h5, h6 {
            color: var(--scopy-text-primary);
            font-family: var(--scopy-chatgpt-font);
            font-weight: 600;
            padding: 0;
            border: 0;
          }
          h1 {
            font-size: 24px;
            line-height: 32px;
            letter-spacing: normal;
            margin: 0 0 8px 0;
          }
          h2 {
            font-size: 20px;
            line-height: 28px;
            margin: 16px 0 4px 0;
          }
          h3 {
            font-size: 18px;
            line-height: 28px;
            margin: 16px 0 4px 0;
          }
          h4 {
            font-size: 16px;
            line-height: 24px;
            margin: 16px 0 0 0;
          }
          h5 {
            font-size: 16px;
            line-height: 26px;
            margin: 0;
          }
          h6 {
            font-size: 16px;
            line-height: 26px;
            font-weight: 400;
            margin: 0;
          }
          p {
            margin: 8px 0 4px 0;
            font-size: 16px;
            line-height: 26px;
            font-weight: 400;
            color: var(--scopy-text-primary);
          }
          p + p {
            margin: 16px 0;
          }
          ul, ol {
            margin: 0;
            padding-left: 26px;
            font-size: 16px;
            line-height: 26px;
            font-weight: 400;
          }
          ul {
            list-style-type: disc;
          }
          ol {
            list-style-type: decimal;
          }
          li {
            min-height: 26px;
            margin: 0;
            padding-left: 6px;
            font-size: 16px;
            line-height: 26px;
            font-weight: 400;
          }
          li::marker {
            font-size: 16px;
            line-height: 26px;
            font-weight: 700;
            color: currentColor;
          }
          li > p {
            margin-top: 0;
            margin-bottom: 0;
            line-height: 26px;
          }
          li > ul,
          li > ol {
            margin-top: 0;
            margin-bottom: 0;
            padding-left: 26px;
          }
          strong {
            font-weight: 600;
          }
          em {
            font-style: italic;
          }
          del, s {
            text-decoration-line: line-through;
          }
          pre, code {
            font-family: var(--scopy-chatgpt-mono);
          }
          h1 code,
          h2 code,
          h3 code,
          h4 code,
          h5 code,
          h6 code,
          #content h1 code,
          #content h2 code,
          #content h3 code,
          #content h4 code,
          #content h5 code,
          #content h6 code,
          h1 .qN-_1G_InlineCode,
          h2 .qN-_1G_InlineCode,
          h3 .qN-_1G_InlineCode,
          h4 .qN-_1G_InlineCode,
          h5 .qN-_1G_InlineCode,
          h6 .qN-_1G_InlineCode {
            padding: 0;
            border-radius: 0;
            background: transparent;
            box-shadow: none;
            color: inherit;
            font-family: inherit;
            font-size: inherit;
            line-height: inherit;
            font-weight: inherit;
            white-space: normal;
          }
          p code,
          li code,
          td code,
          th code,
          blockquote code {
            padding: 2.4px 4.8px;
            border-radius: 4px;
            background: var(--scopy-code-bg);
            box-shadow: inset 0 0 0 1px var(--scopy-code-border);
            font-size: 14px;
            line-height: 26px;
            font-weight: 500;
            white-space: nowrap;
          }
          pre {
            position: relative;
            margin: 16px 0 4px 0;
            padding: 48px 20px 12px 20px;
            border: 1px solid var(--scopy-code-card-border);
            border-radius: 24px;
            overflow-x: auto;
            max-width: 100%;
            box-sizing: border-box;
            color: var(--scopy-text-primary);
            background: var(--scopy-code-card-bg);
            box-shadow: none;
            font-size: 12.25px;
            line-height: 20px;
            font-weight: 400;
            white-space: pre;
          }
          pre::before {
            content: "</>";
            position: absolute;
            left: 20px;
            right: 6px;
            top: 6px;
            height: 24px;
            font-family: var(--scopy-chatgpt-font);
            font-size: 14px;
            line-height: 24px;
            font-weight: 400;
            color: var(--scopy-text-primary);
            white-space: nowrap;
          }
          pre:has(> code.language-bash)::before,
          pre:has(> code.language-sh)::before,
          pre:has(> code.language-shell)::before,
          pre:has(> code.language-zsh)::before { content: "</> Bash"; }
          pre:has(> code.language-cpp)::before,
          pre:has(> code.language-cxx)::before { content: "</> C++"; }
          pre:has(> code.language-diff)::before { content: "</> Diff"; }
          pre:has(> code.language-env)::before { content: "</> env"; }
          pre:has(> code.language-html)::before { content: "</> HTML"; }
          pre:has(> code.language-java)::before { content: "</> Java"; }
          pre:has(> code.language-javascript)::before,
          pre:has(> code.language-js)::before,
          pre:has(> code.language-jsx)::before { content: "</> JavaScript"; }
          pre:has(> code.language-json)::before { content: "</> JSON"; }
          pre:has(> code.language-markdown)::before,
          pre:has(> code.language-md)::before { content: "</> Markdown"; }
          pre:has(> code.language-mermaid)::before { content: "</> Mermaid"; }
          pre:has(> code.language-python)::before,
          pre:has(> code.language-py)::before { content: "</> Python"; }
          pre:has(> code.language-sql)::before { content: "</> SQL"; }
          pre:has(> code.language-text)::before,
          pre:has(> code.language-txt)::before,
          pre:has(> code.language-plain)::before,
          pre:has(> code.language-plaintext)::before { content: "</> text"; }
          pre:has(> code.language-yaml)::before,
          pre:has(> code.language-yml)::before { content: "</> YAML"; }
          pre code {
            display: block;
            padding: 0;
            background: transparent;
            border-radius: 0;
            font-size: 12.25px;
            line-height: 20px;
            white-space: pre;
            word-break: normal;
            overflow-wrap: normal;
            min-width: max-content;
          }
          pre span {
            background: transparent;
            padding: 0;
          }
          .hljs {
            background: transparent;
            color: var(--scopy-syntax-base);
          }
          .hljs-doctag,
          .hljs-keyword,
          .hljs-formula,
          .hljs-meta .hljs-keyword {
            color: var(--scopy-syntax-keyword);
          }
          .hljs-section,
          .hljs-name,
          .hljs-selector-tag,
          .hljs-deletion,
          .hljs-subst {
            color: var(--scopy-syntax-name);
          }
          .hljs-literal {
            color: var(--scopy-syntax-literal);
          }
          .hljs-meta .hljs-string,
          .hljs-regexp,
          .hljs-string,
          .hljs-addition,
          .hljs-attribute {
            color: var(--scopy-syntax-string);
          }
          .hljs-built_in,
          .hljs-class .hljs-title {
            color: var(--scopy-syntax-built-in);
          }
          .hljs-attr,
          .hljs-selector-attr,
          .hljs-selector-class,
          .hljs-selector-pseudo,
          .hljs-template-variable,
          .hljs-type,
          .hljs-variable,
          .hljs-number {
            color: var(--scopy-syntax-number);
          }
          .hljs-symbol,
          .hljs-bullet,
          .hljs-link,
          .hljs-meta,
          .hljs-selector-id,
          .hljs-title {
            color: var(--scopy-syntax-symbol);
          }
          .hljs-code,
          .hljs-comment,
          .hljs-quote {
            color: var(--scopy-syntax-comment);
            font-style: italic;
          }
          .hljs-operator,
          .hljs-tag,
          .hljs-template-tag,
          .hljs-variable.language_ {
            color: var(--scopy-syntax-base);
          }
          .hljs-emphasis {
            font-style: italic;
          }
          .hljs-strong {
            font-weight: 700;
          }
          html.scopy-export-mode #content-scale-shell {
            width: var(--scopy-chatgpt-render-width);
            max-width: none;
          }
          html.scopy-export-mode #content {
            box-shadow: none;
            border: 0;
            border-radius: 0;
            transform: none;
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
            color: var(--scopy-text-primary);
            text-decoration-line: underline;
            text-decoration-style: dotted;
            text-decoration-color: rgb(143, 143, 143);
            text-underline-offset: 2px;
          }
          a::after {
            content: "↗";
            display: inline-block;
            width: 12px;
            height: 12px;
            margin-left: 0.125rem;
            font-size: 16px;
            line-height: 16px;
            vertical-align: middle;
            text-decoration: none;
          }
          blockquote {
            position: relative;
            margin: 0 0 8px 0;
            padding: 8px 0 8px 24px;
            border: 0;
            color: var(--scopy-text-primary);
            font-size: 16px;
            line-height: 24px;
            font-weight: 400;
          }
          blockquote::after {
            content: "";
            display: block;
            position: absolute;
            left: 0;
            top: 8px;
            bottom: 8px;
            width: 4px;
            background-color: var(--scopy-border);
            border-radius: 2px;
          }
          blockquote > p {
            margin-top: 0;
            margin-bottom: 0;
            font-size: 16px;
            line-height: 24px;
            font-weight: 400;
          }
          blockquote ul,
          blockquote ol {
            margin-top: 0;
            margin-bottom: 0;
            padding-left: 26px;
            font-size: 16px;
            line-height: 24px;
            font-weight: 400;
          }
          hr {
            border: 0;
            border-top: 1px solid var(--scopy-border-subtle);
            margin: 32px 0;
          }
          .katex {
            color: var(--scopy-text-primary);
          }
          .katex-display {
            max-width: 100%;
            overflow-x: auto;
            overflow-y: hidden;
            margin: 16px 0;
            font-size: 16px;
            line-height: 26px;
          }
          .scopy-chatgpt-table-container {
            display: block;
            overflow-x: auto;
            overflow-y: hidden;
            margin: 32px 0;
            width: 100%;
            max-width: 100%;
            -webkit-overflow-scrolling: touch;
            scrollbar-width: none;
            --scopy-chatgpt-wide-table-col-baseline: var(--scopy-chatgpt-thread-content-width);
          }
          table {
            display: table;
            border-collapse: separate;
            border-spacing: 0;
            min-width: 100%;
            width: 100%;
            max-width: none;
            table-layout: auto;
            overflow: visible;
            border: 0;
            margin: 0;
            font-family: var(--scopy-chatgpt-font);
            font-size: 14px;
            line-height: 24px;
          }
          th, td {
            border: 0;
            padding-inline: 0;
            text-align: start;
            white-space: normal;
            word-break: normal;
            overflow-wrap: break-word;
          }
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table > table {
            width: fit-content;
            min-width: 100%;
          }
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table th[data-scopy-col-size="sm"],
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table td[data-scopy-col-size="sm"] {
            min-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 4 / 24);
            max-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 6 / 24);
          }
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table th[data-scopy-col-size="md"],
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table td[data-scopy-col-size="md"] {
            min-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 6 / 24);
            max-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 8 / 24);
          }
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table th[data-scopy-col-size="lg"],
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table td[data-scopy-col-size="lg"] {
            min-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 8 / 24);
            max-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 12 / 24);
          }
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table th[data-scopy-col-size="xl"],
          .scopy-chatgpt-table-container.scopy-chatgpt-wide-table td[data-scopy-col-size="xl"] {
            min-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 14 / 24);
            max-width: calc(var(--scopy-chatgpt-wide-table-col-baseline) * 18 / 24);
          }
          th:not(:last-child),
          td:not(:last-child) {
            padding-inline-end: 24px;
          }
          thead th {
            border-bottom: 1px solid var(--scopy-border);
            color: var(--scopy-text-primary);
            font-weight: 600;
            line-height: 20px;
            padding-block: 8px;
            vertical-align: bottom;
          }
          tbody td {
            border-bottom: 1px solid var(--scopy-border-subtle);
          }
          tbody tr:last-child td {
            border-bottom: 0;
          }
          tbody td {
            padding-block: 10px;
            vertical-align: baseline;
          }
          tfoot td {
            border-top: 1px solid var(--scopy-border);
            border-bottom: 0;
            vertical-align: top;
          }
          \(taskListStyle)\(footnoteStyle)\(definitionListStyle)\(safeHTMLStyle)
          /* Hide scrollbars inside HTML when idle (even if system setting is "always show scroll bars").
             We show them temporarily while the user is actively scrolling overflow containers (JS toggles the class). */
          pre::-webkit-scrollbar,
          .scopy-chatgpt-table-container::-webkit-scrollbar,
          table::-webkit-scrollbar,
          .katex-display::-webkit-scrollbar,
          .footnotes::-webkit-scrollbar,
          details::-webkit-scrollbar {
            width: 0px;
            height: 0px;
          }
          html.scopy-scrollbars-visible pre::-webkit-scrollbar,
          html.scopy-scrollbars-visible .scopy-chatgpt-table-container::-webkit-scrollbar,
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

    static func legacyDocument(
        featureSet: MarkdownRenderFeatureSet,
        markdown: String,
        placeholders: [(placeholder: String, original: String)],
        safeHTMLReplacements: [String: MarkdownSafeHTMLSubset.Replacement],
        enableMath: Bool,
        fallbackText: String,
        renderSentinel: String?
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
        let renderSentinelLiteral = jsonLiteral(renderSentinel)
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
                      var label = tokens[idx].meta && tokens[idx].meta.label ? String(tokens[idx].meta.label) : '';
                      var n = label || Number(tokens[idx].meta.id + 1).toString();
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
                var refs = root.querySelectorAll('sup.footnote-ref > a, sup > a[data-footnote-ref]');
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
            \(tableWrapFunctionScript)
            window.__scopyReportHeight = function (force) {
              try {
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopySize) { return; }
                var el = document.getElementById('content');
                if (!el) { return; }
                scaleChatGPTTables(el);
                var previewScale = updateChatGPTPreviewScale(el);
                var box = document.getElementById('content-scale-shell') || el;
                var rect = box.getBoundingClientRect();
                var w = Math.ceil(rect.width || 0);
                var sh = Math.ceil(el.scrollHeight || 0);
                var h = Math.ceil(Math.max(rect.height || 0, sh * previewScale));
                var overflowX = false;
                try {
                  // Detect horizontal scroll requirement inside common overflow containers (KaTeX display, code blocks, tables).
                  // We use this signal to prefer a wider popover, while keeping the outer scroll view's horizontal scroller disabled.
                  var nodes = el.querySelectorAll(\(overflowSelectorLiteral));
                  for (var i = 0; i < nodes.length; i++) {
                    var n = nodes[i];
                    if (!n) { continue; }
                    if (n.classList && n.classList.contains('scopy-chatgpt-table-container') && n.dataset && n.dataset.scopyTableScaled === 'true') { continue; }
                    var cw = n.clientWidth || 0;
                    var sw = n.scrollWidth || 0;
                    if (cw > 0 && (sw - cw) > 1) { overflowX = true; break; }
                  }
                  // Table-local overflow should not request a wider Swift popover. ChatGPT keeps wide tables inside
                  // the message column and scrolls the table container itself; non-table overflow is detected by the
                  // explicit selector above.
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
                function escapeRegExp(text) {
                  return String(text || '')
                    .replace(/[\\\\^.*+?()[\\]{}|]/g, '\\\\$&')
                    .replace(/\\$/g, '\\\\$&');
                }
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

                var keys = Object.keys(safeHTMLMap || {}).sort(function (a, b) { return b.length - a.length; });
                for (var i = 0; i < keys.length; i++) {
                  var key = keys[i];
                  if (html.indexOf(key) === -1) { continue; }
                  var paragraphPattern = new RegExp('<p>\\\\s*' + escapeRegExp(key) + '\\\\s*<\\\\/p>', 'g');
                  html = html.replace(paragraphPattern, function () {
                    return renderSafeHTMLToken(key);
                  });
                }
                for (var j = 0; j < keys.length; j++) {
                  var token = keys[j];
                  if (html.indexOf(token) === -1) { continue; }
                  html = html.split(token).join(renderSafeHTMLToken(token));
                }
                return html;
              }

              var mdOptions = \(featureSet.markdownItOptionsJSLiteral);
              var renderSentinel = \(renderSentinelLiteral);
              \(highlightOptionsScript)
              var md = window.markdownit(mdOptions);
              \(footnotesInstallScript)\(definitionListInstallScript)
              if (md && typeof md.enable === 'function') {
                \(featureSet.markdownItEnableStatementsJS)
              }
              var src = \(markdownLiteral);
              var html = md.render(src);
              var map = \(placeholdersLiteral);
              Object.keys(map || {}).sort(function (a, b) { return b.length - a.length; }).forEach(function (key) {
                html = html.split(key).join(map[key] || key);
              });
              html = applySafeHTMLReplacements(html, md);
              if (renderSentinel) {
                html = html.split(renderSentinel).join('');
              }
              el.innerHTML = html;
              wrapChatGPTTables(el);
              scaleChatGPTTables(el);
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
                ro = new ResizeObserver(function () { scaleChatGPTTables(el); scheduleReportHeight(); });
                try { ro.observe(el); } catch (e) { }
              }

              if (document.fonts && document.fonts.ready && typeof document.fonts.ready.then === 'function') {
                document.fonts.ready.then(function () { scaleChatGPTTables(el); scheduleReportHeight(); }).catch(function () { });
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
              window.addEventListener('resize', function () {
                scheduleReportHeight();
                setTimeout(scheduleReportHeight, 60);
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
            <div id="content-scale-shell"><div id="content"><pre>\(escapeHTML(fallbackText))</pre></div></div>
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

    static func unifiedDocument(markdown: String, context: MarkdownRenderContext) -> String {
        let markdownLiteral = jsonLiteral(markdown)
        let policyLiteral = jsonLiteral(unifiedPolicyPayload(context: context))
        let overflowSelectorLiteral = jsonStringLiteral(MarkdownRenderFeatureSet.scopyDefault.overflowProbeSelector)
        let taskListBootstrapScript = MarkdownTaskListRuntime.bootstrapScript

        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            \(cspMetaTag)
            <link rel="stylesheet" href="katex.min.css">
            <script defer src="contrib/scopy-unified-renderer.iife.js"></script>
            \(baseStyle(featureSet: MarkdownRenderFeatureSet.scopyDefault))
            \(taskListBootstrapScript)
            <script>
              (function () {
                window.__scopyRenderState = window.__scopyRenderState || {
                  renderComplete: false,
                  markdownRendered: false,
                  renderFailed: false,
                  unifiedRenderSucceeded: false,
                  renderPass: 0
                };
                var lastH = 0;
                var lastW = 0;
                var unifiedRenderAttempts = 0;
                var maxUnifiedRenderAttempts = 100;
                window.__scopyIsRenderReady = function () {
                  try {
                    var state = window.__scopyRenderState || {};
                    return !!state.renderComplete && !!state.markdownRendered && !state.renderFailed && state.unifiedRenderSucceeded !== false;
                  } catch (e) {
                    return false;
                  }
                };
                window.__scopyRenderMath = window.__scopyRenderMath || function () {
                  if (typeof window.__scopyReportHeight === 'function') {
                    window.__scopyReportHeight();
                  }
                };
                \(tableWrapFunctionScript)
                window.__scopyReportHeight = function (force) {
                  try {
                    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopySize) { return; }
                    var el = document.getElementById('content');
                    if (!el) { return; }
                    scaleChatGPTTables(el);
                    var previewScale = updateChatGPTPreviewScale(el);
                    var box = document.getElementById('content-scale-shell') || el;
                    var rect = box.getBoundingClientRect();
                    var w = Math.ceil(rect.width || 0);
                    var sh = Math.ceil(el.scrollHeight || 0);
                    var h = Math.ceil(Math.max(rect.height || 0, sh * previewScale));
                    var overflowX = false;
                    try {
                      var nodes = el.querySelectorAll(\(overflowSelectorLiteral));
                      for (var i = 0; i < nodes.length; i++) {
                        var n = nodes[i];
                        if (!n) { continue; }
                        if (n.classList && n.classList.contains('scopy-chatgpt-table-container') && n.dataset && n.dataset.scopyTableScaled === 'true') { continue; }
                        var cw = n.clientWidth || 0;
                        var sw = n.scrollWidth || 0;
                        if (cw > 0 && (sw - cw) > 1) {
                          overflowX = true;
                          break;
                        }
                      }
                      // Table-local overflow should not request a wider Swift popover. ChatGPT keeps wide tables inside
                      // the message column and scrolls the table container itself; non-table overflow is detected by the
                      // explicit selector above.
                    } catch (e) {
                      overflowX = false;
                    }
                    if (!h) { return; }
                    if (!force && Math.abs(h - lastH) < 1 && Math.abs(w - lastW) < 1) { return; }
                    lastH = h;
                    lastW = w;
                    var state = window.__scopyRenderState || {};
                    window.webkit.messageHandlers.scopySize.postMessage({
                      width: w,
                      height: h,
                      overflowX: overflowX,
                      renderSucceeded: !state.renderFailed && !!state.markdownRendered && state.unifiedRenderSucceeded !== false,
                      renderErrorReason: state.unifiedErrorReason || ''
                    });
                  } catch (e) { }
                };
                function finish(succeeded) {
                  var el = document.getElementById('content');
                  if (el) {
                    try { el.style.opacity = '1'; } catch (e) { }
                  }
                  try {
                    if (window.__scopyRenderState) {
                      window.__scopyRenderState.markdownRendered = !!succeeded;
                      window.__scopyRenderState.renderComplete = true;
                    }
                  } catch (e) { }
                  if (typeof window.__scopyReportHeight === 'function') {
                    window.__scopyReportHeight(true);
                    setTimeout(function () {
                      window.__scopyReportHeight(true);
                    }, 120);
                  }
                }
                function failUnifiedRender(reason) {
                  var el = document.getElementById('content');
                  if (!el) { return; }
                  try {
                    if (window.__scopyRenderState) {
                      window.__scopyRenderState.unifiedErrorReason = reason || 'unified render failed';
                      window.__scopyRenderState.renderFailed = true;
                      window.__scopyRenderState.unifiedRenderSucceeded = false;
                    }
                  } catch (e) { }
                  el.innerHTML = '<p class="scopy-render-error">Markdown renderer failed to load.</p>';
                  finish(false);
                }
                function renderUnified() {
                  var el = document.getElementById('content');
                  if (!el) { return; }
                  try {
                    if (window.__scopyRenderState) {
                      window.__scopyRenderState.renderComplete = false;
                      window.__scopyRenderState.markdownRendered = false;
                      window.__scopyRenderState.renderFailed = false;
                      window.__scopyRenderState.unifiedRenderSucceeded = false;
                      window.__scopyRenderState.unifiedErrorReason = '';
                      window.__scopyRenderState.renderPass = (window.__scopyRenderState.renderPass || 0) + 1;
                    }
                  } catch (e) { }
                  if (!window.ScopyUnifiedMarkdown || typeof window.ScopyUnifiedMarkdown.render !== 'function') {
                    unifiedRenderAttempts += 1;
                    if (unifiedRenderAttempts >= maxUnifiedRenderAttempts) {
                      failUnifiedRender('unified api missing');
                      return;
                    }
                    setTimeout(renderUnified, 30);
                    return;
                  }
                  unifiedRenderAttempts = 0;
                  try {
                    var result = window.ScopyUnifiedMarkdown.render(\(markdownLiteral), \(policyLiteral));
                    if (result && result.html) {
                      el.innerHTML = result.html;
                      if (typeof window.__scopyApplyTaskLists === 'function') {
                        window.__scopyApplyTaskLists(el);
                      }
                      wrapChatGPTTables(el);
                      scaleChatGPTTables(el);
                      if (window.__scopyRenderState) {
                        window.__scopyRenderState.unifiedRenderSucceeded = true;
                      }
                    } else {
                      failUnifiedRender('unified returned empty html');
                      return;
                    }
                  } catch (e) {
                    failUnifiedRender('unified render exception');
                    return;
                  }
                  finish(true);
                }
                if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', renderUnified);
                } else {
                  renderUnified();
                }
                if (window && typeof window.addEventListener === 'function') {
                  window.addEventListener('load', function () {
                    if (typeof window.__scopyReportHeight === 'function') {
                      window.__scopyReportHeight(true);
                      setTimeout(function () { window.__scopyReportHeight(true); }, 120);
                    }
                  });
                  window.addEventListener('resize', function () {
                    if (typeof window.__scopyReportHeight === 'function') {
                      window.__scopyReportHeight(true);
                      setTimeout(function () { window.__scopyReportHeight(true); }, 60);
                    }
                  });
                }
              })();
            </script>
          </head>
          <body>
            <div id="content-scale-shell"><div id="content"></div></div>
          </body>
        </html>
        """
    }

    private static func unifiedPolicyPayload(context: MarkdownRenderContext) -> [String: AnyEncodable] {
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
