import Foundation
import ScopyKit

enum MarkdownHTMLDocumentBuilder {
    private static let layout = MarkdownRenderLayoutConstants.self
    private static let overflowProbeSelector = "pre, .katex, .footnotes"

    private static let cspMetaTag = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline' file:; script-src 'self' 'unsafe-inline' file:; font-src 'self' data: file:;">
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
            function chatGPTMarkdownTableColumnSize(length) {
              if (length > 160) { return 'xl'; }
              if (length > 100) { return 'lg'; }
              if (length > 40) { return 'md'; }
              return 'sm';
            }
            function sizeChatGPTMarkdownTableColumns(wrapper, table) {
              try {
                if (!wrapper || !table || !table.querySelectorAll) { return; }
                var columns = readChatGPTTableColumnCount(table);
                var lengths = readChatGPTTableColumnLengths(table, columns);
                wrapper.classList.add('scopy-chatgpt-sized-table');
                wrapper.classList.add('scopy-chatgpt-markdown-table');
                wrapper.setAttribute('data-scopy-table-model', 'markdown-pipe');
                table.classList.add('scopy-chatgpt-sized-table');
                table.classList.add('scopy-chatgpt-markdown-table');
                table.setAttribute('data-scopy-table-model', 'markdown-pipe');
                var rows = table.querySelectorAll('tr');
                for (var r = 0; r < (rows.length || 0); r++) {
                  var cells = rows[r] && rows[r].children;
                  if (!cells) { continue; }
                  for (var c = 0; c < cells.length; c++) {
                    var size = c < lengths.length ? chatGPTMarkdownTableColumnSize(lengths[c] || 0) : 'sm';
                    cells[c].setAttribute('data-col-size', size);
                    cells[c].setAttribute('data-scopy-col-size', size);
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
                  if (parent && parent.classList && parent.classList.contains('scopy-chatgpt-table-wrapper')) {
                    var existingContainer = parent.parentElement;
                    if (existingContainer && existingContainer.classList && existingContainer.classList.contains('scopy-chatgpt-table-container')) {
                      sizeChatGPTMarkdownTableColumns(existingContainer, table);
                      continue;
                    }
                  }
                  if (parent && parent.classList && parent.classList.contains('scopy-chatgpt-table-container')) {
                    var existingWrapper = document.createElement('div');
                    existingWrapper.className = 'scopy-chatgpt-table-wrapper';
                    parent.insertBefore(existingWrapper, table);
                    existingWrapper.appendChild(table);
                    sizeChatGPTMarkdownTableColumns(parent, table);
                    continue;
                  }
                  var wrapper = document.createElement('div');
                  wrapper.className = 'scopy-chatgpt-table-container';
                  var tableWrapper = document.createElement('div');
                  tableWrapper.className = 'scopy-chatgpt-table-wrapper';
                  table.parentNode.insertBefore(wrapper, table);
                  wrapper.appendChild(tableWrapper);
                  tableWrapper.appendChild(table);
                  sizeChatGPTMarkdownTableColumns(wrapper, table);
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
              try {
                rectW = Math.ceil(node.getBoundingClientRect().width || 0);
                var zoom = currentChatGPTPreviewScale();
                if (zoom && isFinite(zoom) && zoom > 0 && zoom !== 1) { rectW = Math.ceil(rectW / zoom); }
              } catch (e) { rectW = 0; }
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
            function syncChatGPTZoomShell(content) {
              try {
                var root = document.documentElement;
                if (!root || !content) { return 1; }
                var shell = document.getElementById('content-scale-shell');
                var zoom = readCSSPixelVariable(root, '--scopy-chatgpt-browser-zoom', 1);
                var renderWidth = readCSSPixelVariable(root, '--scopy-chatgpt-render-width', 0);
                var visualWidth = (renderWidth && isFinite(renderWidth) && renderWidth > 0) ? renderWidth * zoom : 0;
                var fit = 1;
                var isExportMode = false;
                try { isExportMode = root.classList && root.classList.contains('scopy-export-mode'); } catch (e) { isExportMode = false; }
                if (!isExportMode && visualWidth && isFinite(visualWidth) && visualWidth > 0) {
                  var viewportWidth = 0;
                  try { viewportWidth = Math.ceil(window.innerWidth || 0); } catch (e) { viewportWidth = 0; }
                  if (!viewportWidth || !isFinite(viewportWidth) || viewportWidth <= 0) {
                    try { viewportWidth = Math.ceil(root.clientWidth || 0); } catch (e) { viewportWidth = 0; }
                  }
                  if (viewportWidth && isFinite(viewportWidth) && viewportWidth > 0 && viewportWidth < visualWidth) {
                    fit = Math.max(0.01, viewportWidth / visualWidth);
                  }
                }
                var scale = zoom * fit;
                root.style.setProperty('--scopy-chatgpt-preview-fit-scale', String(fit));
                root.style.setProperty('--scopy-chatgpt-preview-scale', String(scale));
                if (shell && shell.style) {
                  if (renderWidth && isFinite(renderWidth) && renderWidth > 0) {
                    shell.style.width = Math.max(1, Math.round(renderWidth * scale)) + 'px';
                  } else {
                    shell.style.width = '';
                  }
                  shell.style.maxWidth = '';
                  var rawHeight = 0;
                  try { rawHeight = Math.ceil(content.scrollHeight || content.offsetHeight || 0); } catch (e) { rawHeight = 0; }
                  if (rawHeight && isFinite(rawHeight) && rawHeight > 0) {
                    shell.style.height = Math.ceil(rawHeight * scale) + 'px';
                  } else {
                    shell.style.height = '';
                  }
                }
                return scale;
              } catch (e) {
                return 1;
              }
            }
            function updateChatGPTPreviewScale(content) {
              return syncChatGPTZoomShell(content);
            }
            window.syncChatGPTZoomShell = syncChatGPTZoomShell;
            function layoutChatGPTTables(root) {
              try {
                if (!root || typeof root.querySelectorAll !== 'function') { return; }
                wrapChatGPTTables(root);
                var isExportMode = false;
                try { isExportMode = document.documentElement && document.documentElement.classList && document.documentElement.classList.contains('scopy-export-mode'); } catch (e) { isExportMode = false; }
                if (isExportMode) { return; }
                var containers = root.querySelectorAll('.scopy-chatgpt-table-container');
                for (var i = 0; i < (containers.length || 0); i++) {
                  var container = containers[i];
                  if (!container) { continue; }
                  var table = container.querySelector('table');
                  if (!table) { continue; }
                  resetChatGPTTableScale(container, table);
                }
              } catch (e) { }
            }
            function scaleChatGPTTablesForExport(root, explicitTargetWidth) {
              try {
                if (!root || typeof root.querySelectorAll !== 'function') { return; }
                wrapChatGPTTables(root);
                var targetWidth = Number(explicitTargetWidth || 0);
                if (!targetWidth || !isFinite(targetWidth) || targetWidth <= 0) { return; }
                var containers = root.querySelectorAll('.scopy-chatgpt-table-container');
                for (var i = 0; i < (containers.length || 0); i++) {
                  var container = containers[i];
                  if (!container) { continue; }
                  var table = container.querySelector('table');
                  if (!table) { continue; }
                  resetChatGPTTableScale(container, table);
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
            try {
              window.__scopyLayoutChatGPTTables = layoutChatGPTTables;
              window.__scopyScaleChatGPTTablesForExport = scaleChatGPTTablesForExport;
            } catch (e) { }
    """

    private static func baseStyle(layoutScale: MarkdownChatGPTLayoutScalePercent) -> String {
        let outputSurfaceWidth = Self.layout.chatGPTOutputSurfaceWidth
        let layoutViewportWidth = layoutScale.layoutViewportWidth(outputSurfaceWidth: outputSurfaceWidth)
        let threadContentWidth = Self.layout.threadContentWidth(
            forLayoutViewportWidth: layoutViewportWidth
        )
        let fontScale = layoutScale.fontScale
        let browserZoomScale = layoutScale.browserZoomScale
        let inverseBrowserZoomScale = layoutScale.inverseBrowserZoomScale
        let taskListStyle = "\n\(MarkdownTaskListRuntime.style)\n"
        let footnoteStyle = """
          .footnotes {
            margin-top: 16px;
            padding-top: 0;
            border-top: 0;
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
          }
          .footnotes-list {
            margin: 0;
            padding-inline-start: 26px;
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
            margin-inline-start: 4px;
            font-size: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
            vertical-align: baseline;
          }
          sup:has(> a[data-footnote-ref]) {
            display: inline-flex;
            position: static;
            top: auto;
            margin-inline-start: 4px;
            font-size: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
            vertical-align: baseline;
          }
          .footnote-ref a,
          a[data-footnote-ref],
          .footnote-backref,
          a[data-footnote-backref] {
            pointer-events: auto;
            color: rgb(95, 95, 95);
            font-weight: 500;
            text-decoration: none;
            cursor: pointer;
          }
          .footnote-ref a,
          a[data-footnote-ref] {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            min-width: 0;
            height: calc(25px * var(--scopy-chatgpt-layout-font-scale));
            min-height: calc(25px * var(--scopy-chatgpt-layout-font-scale));
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
        """
        return """
        <style>
          :root {
            color-scheme: light;
            --scopy-chatgpt-font: -apple-system-body, ui-sans-serif, -apple-system, "system-ui", "Segoe UI", Helvetica, "Apple Color Emoji", Arial, "sans-serif", "Segoe UI Emoji", "Segoe UI Symbol";
            --scopy-chatgpt-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
            --scopy-text-primary: rgb(13, 13, 13);
            --scopy-page-bg: #fcfcfc;
            --scopy-surface-bg: #ffffff;
            --scopy-text-weak: rgb(143, 143, 143);
            --scopy-rich-border: rgba(0, 0, 0, 0.10);
            --scopy-rich-border-strong: rgba(0, 0, 0, 0.10);
            --scopy-rich-card-radius: 20px;
            --scopy-rich-card-padding: 20px;
            --scopy-rich-control-radius: 10px;
            --scopy-rich-column-gap: 16px;
            --scopy-rich-image-gap: 4px;
            --scopy-rich-news-card-ideal-width: 15.33rem;
            --scopy-rich-image-slot-min-width: 8rem;
            --scopy-rich-range-min-width: 4.5rem;
            /* Trend palette sampled from the 2026-08-28 ChatGPT desktop reference screenshots
               (live/runtime-derived). SVG chart gradients inherit these through currentColor,
               so this block is the single color authority for every trend-colored surface. */
            --scopy-rich-trend-up-text: rgb(38, 112, 46);
            --scopy-rich-trend-up-stroke: rgb(75, 158, 83);
            --scopy-rich-trend-down: rgb(239, 65, 70);
            --scopy-rich-weather-chart-warm: rgb(238, 147, 64);
            --scopy-link-color: rgb(46, 131, 210);
            --scopy-code-bg: rgba(13, 13, 13, 0.04);
            --scopy-code-border: rgba(13, 13, 13, 0.08);
            --scopy-code-card-bg: rgb(249, 249, 249);
            --scopy-code-card-border: rgba(13, 13, 13, 0.05);
            --scopy-border: rgba(13, 13, 13, 0.15);
            --scopy-border-subtle: rgba(13, 13, 13, 0.10);
            --scopy-text-secondary: rgb(93, 93, 93);
            --scopy-syntax-base: rgb(13, 13, 13);
            --scopy-syntax-comment: #4f4f4f;
            --scopy-syntax-meta: #004f99;
            --scopy-syntax-keyword: #ba437a;
            --scopy-syntax-heading: #ba8e00;
            --scopy-syntax-atom: #b9480d;
            --scopy-syntax-string: #008635;
            --scopy-syntax-standard-name: #b9480d;
            --scopy-syntax-name: #6b3ab4;
            --scopy-syntax-attribute: #ba8e00;
            --scopy-syntax-tag: #004f99;
            --scopy-syntax-invalid: #ba2623;
            --scopy-chatgpt-layout-font-scale: \(fontScale);
            --scopy-chatgpt-browser-zoom: \(browserZoomScale);
            --scopy-chatgpt-inverse-browser-zoom: \(inverseBrowserZoomScale);
            --scopy-chatgpt-output-surface-width: \(outputSurfaceWidth)px;
            --scopy-chatgpt-layout-viewport-width: \(layoutViewportWidth)px;
            --scopy-chatgpt-thread-content-max-width: \(threadContentWidth)px;
            --scopy-chatgpt-content-inline-padding: \(Self.layout.chatGPTContentInlinePadding)px;
            --scopy-chatgpt-content-top-padding: \(Self.layout.chatGPTContentTopPadding)px;
            --scopy-chatgpt-content-bottom-padding: \(Self.layout.chatGPTContentBottomPadding)px;
            --scopy-chatgpt-body-font-size: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-body-line-height: calc(26px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-quote-line-height: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h1-font-size: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h1-line-height: calc(32px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h2-font-size: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h2-line-height: calc(28px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h3-font-size: calc(18px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h3-line-height: calc(28px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h4-font-size: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-h4-line-height: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-code-card-font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-code-card-line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            --scopy-chatgpt-thread-content-width: min(
              var(--scopy-chatgpt-thread-content-max-width),
              max(1px, calc(var(--scopy-chatgpt-render-width) - (var(--scopy-chatgpt-content-inline-padding) * 2)))
            );
            --scopy-chatgpt-render-width: var(--scopy-chatgpt-layout-viewport-width);
            --scopy-chatgpt-markdown-table-col-baseline: var(--scopy-chatgpt-thread-content-max-width);
            --scopy-chatgpt-table-breakout-width: var(--scopy-chatgpt-thread-content-width);
            --scopy-chatgpt-preview-scale: var(--scopy-chatgpt-browser-zoom);
            --scopy-chatgpt-preview-fit-scale: 1;
          }
          body {
            margin: 0;
            padding: 0;
            font-family: var(--scopy-chatgpt-font);
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
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
            width: calc(var(--scopy-chatgpt-render-width) * var(--scopy-chatgpt-preview-scale));
            max-width: none;
            margin: 0;
            padding: 0;
            overflow: visible;
            transform-origin: top left;
          }
          #content {
            display: block;
            width: var(--scopy-chatgpt-render-width);
            max-width: none;
            padding: var(--scopy-chatgpt-content-top-padding) var(--scopy-chatgpt-content-inline-padding) var(--scopy-chatgpt-content-bottom-padding) var(--scopy-chatgpt-content-inline-padding);
            box-sizing: border-box;
            overflow-wrap: anywhere;
            word-break: normal;
            color: var(--scopy-text-primary);
            background: var(--scopy-page-bg);
            border: 0;
            border-radius: 0;
            box-shadow: none;
            opacity: 1;
            transition: none;
            transform: scale(var(--scopy-chatgpt-preview-scale));
            transform-origin: top left;
          }
          #content > :not(.scopy-chatgpt-table-container) {
            width: 100%;
            max-width: var(--scopy-chatgpt-thread-content-width);
            margin-inline: auto;
          }
          h1, h2, h3, h4, h5, h6 {
            color: var(--scopy-text-primary);
            font-family: var(--scopy-chatgpt-font);
            font-weight: 600;
            padding: 0;
            border: 0;
          }
          h1 {
            font-size: var(--scopy-chatgpt-h1-font-size);
            line-height: var(--scopy-chatgpt-h1-line-height);
            letter-spacing: normal;
            margin: 0 0 8px 0;
          }
          h2 {
            font-size: var(--scopy-chatgpt-h2-font-size);
            line-height: var(--scopy-chatgpt-h2-line-height);
            margin: 16px 0 4px 0;
          }
          h3 {
            font-size: var(--scopy-chatgpt-h3-font-size);
            line-height: var(--scopy-chatgpt-h3-line-height);
            margin: 16px 0 4px 0;
          }
          h4 {
            font-size: var(--scopy-chatgpt-h4-font-size);
            line-height: var(--scopy-chatgpt-h4-line-height);
            margin: 16px 0 0 0;
          }
          h5 {
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            margin: 0;
          }
          h6 {
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            font-weight: 400;
            margin: 0;
          }
          p {
            margin: 4px 0;
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            font-weight: 400;
            color: var(--scopy-text-primary);
          }
          p + p {
            margin: 16px 0;
          }
          ul, ol {
            margin: 0;
            padding-inline-start: 26px;
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            font-weight: 400;
          }
          ul {
            list-style-type: disc;
          }
          ol {
            list-style-type: decimal;
          }
          li {
            min-height: var(--scopy-chatgpt-body-line-height);
            margin: 0;
            padding-inline-start: 6px;
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            font-weight: 400;
          }
          li::marker {
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            font-weight: 700;
            color: currentColor;
          }
          li > p {
            margin-top: 0;
            margin-bottom: 0;
            line-height: var(--scopy-chatgpt-body-line-height);
          }
          li > ul,
          li > ol {
            margin-top: 0;
            margin-bottom: 0;
            padding-inline-start: 26px;
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
          p code,
          li code,
          td code,
          th code,
          blockquote code {
            padding: 2.4px 4.8px;
            border-radius: 4px;
            background: var(--scopy-code-bg);
            box-shadow: inset 0 0 0 1px var(--scopy-code-border);
            font-size: 0.875em;
            line-height: inherit;
            font-weight: 500;
            white-space: normal;
            word-break: normal;
            overflow-wrap: anywhere;
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
            font-size: var(--scopy-chatgpt-code-card-font-size);
            line-height: var(--scopy-chatgpt-code-card-line-height);
            font-weight: 400;
            white-space: pre;
            direction: ltr;
            unicode-bidi: isolate;
            text-align: left;
          }
          pre::before {
            content: "</>";
            position: absolute;
            inset-inline-start: 20px;
            inset-inline-end: 6px;
            top: 6px;
            height: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            font-family: var(--scopy-chatgpt-font);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(24px * var(--scopy-chatgpt-layout-font-scale));
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
            font-size: var(--scopy-chatgpt-code-card-font-size);
            line-height: var(--scopy-chatgpt-code-card-line-height);
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
          .hljs-operator,
          .hljs-template-tag,
          .hljs-formula,
          .hljs-meta .hljs-keyword {
            color: var(--scopy-syntax-keyword);
          }
          .hljs-section,
          .hljs-title {
            color: var(--scopy-syntax-heading);
          }
          .hljs-deletion {
            color: var(--scopy-syntax-invalid);
          }
          .hljs-literal,
          .hljs-number,
          .hljs-symbol,
          .hljs-bullet {
            color: var(--scopy-syntax-atom);
          }
          .hljs-meta .hljs-string,
          .hljs-regexp,
          .hljs-string,
          .hljs-addition {
            color: var(--scopy-syntax-string);
          }
          .hljs-built_in,
          .hljs-class .hljs-title,
          .hljs-title.function_,
          .hljs-variable,
          .hljs-template-variable,
          .hljs-type {
            color: var(--scopy-syntax-name);
          }
          .hljs-attr,
          .hljs-property,
          .hljs-subst,
          .hljs-selector-class,
          .hljs-class {
            color: var(--scopy-syntax-standard-name);
          }
          .hljs-attribute,
          .hljs-selector-attr {
            color: var(--scopy-syntax-attribute);
          }
          .hljs-name,
          .hljs-selector-tag,
          .hljs-selector-pseudo,
          .hljs-link,
          .hljs-meta,
          .hljs-selector-id {
            color: var(--scopy-syntax-tag);
          }
          .hljs-code,
          .hljs-comment,
          .hljs-quote {
            color: var(--scopy-syntax-comment);
            font-style: italic;
          }
          .hljs-tag,
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
            width: calc(var(--scopy-chatgpt-render-width) * var(--scopy-chatgpt-preview-scale));
            max-width: none;
          }
          html.scopy-export-mode #content {
            box-shadow: none;
            border: 0;
            border-radius: 0;
            transform: scale(var(--scopy-chatgpt-preview-scale));
            transform-origin: top left;
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
          u.scopy-safe-html-u {
            text-decoration-line: underline;
            text-decoration-thickness: from-font;
            text-underline-offset: 0.12em;
          }
          kbd.scopy-safe-html-kbd {
            display: inline-flex;
            align-items: center;
            min-height: 1.55em;
            padding: 0 0.38em;
            border: 1px solid var(--scopy-border-subtle);
            border-radius: 5px;
            color: var(--scopy-text-primary);
            background: rgb(247, 247, 247);
            box-shadow: inset 0 -1px 0 rgba(13, 13, 13, 0.12);
            font-family: var(--scopy-chatgpt-mono);
            font-size: 0.82em;
            line-height: 1.45;
            vertical-align: 0.08em;
            white-space: nowrap;
          }
          mark.scopy-safe-html-mark {
            padding: 0.02em 0.16em;
            border-radius: 3px;
            color: inherit;
            background: rgba(250, 204, 21, 0.28);
          }
          sub.scopy-safe-html-sub,
          sup.scopy-safe-html-sup {
            position: relative;
            font-size: 0.72em;
            line-height: 0;
            vertical-align: baseline;
          }
          sub.scopy-safe-html-sub { inset-block-end: -0.25em; }
          sup.scopy-safe-html-sup { inset-block-start: -0.48em; }
          details.scopy-safe-details {
            margin: 12px 0;
            padding: 0 14px;
            border: 1px solid var(--scopy-border-subtle);
            border-radius: 12px;
            background: var(--scopy-page-bg);
          }
          summary.scopy-safe-summary {
            padding: 10px 0;
            font-weight: 600;
            line-height: 1.45;
            cursor: pointer;
          }
          details.scopy-safe-details[open] > summary.scopy-safe-summary {
            margin-block-end: 10px;
            border-block-end: 1px solid var(--scopy-border-subtle);
          }
          details.scopy-safe-details > :last-child { margin-block-end: 12px; }
          html.scopy-export-mode summary.scopy-safe-summary { cursor: default; }
          .scopy-icon {
            display: inline-block;
            flex: 0 0 auto;
            width: 1em;
            height: 1em;
            color: currentColor;
            vertical-align: -0.125em;
          }
          a {
            pointer-events: none;
            color: inherit;
            text-decoration: none;
            cursor: default;
          }
          a.scopy-link--external,
          a.scopy-link--file-resolvable,
          a.scopy-link--internal,
          a.scopy-source-citation-link,
          a.scopy-source-citation-supporting-link,
          .scopy-rich a {
            pointer-events: auto;
            cursor: pointer;
          }
          a.scopy-link--external,
          a.scopy-link--file,
          a.scopy-link--plugin {
            color: var(--scopy-link-color);
            font-weight: 400;
            text-decoration: none;
          }
          a.scopy-link--external:hover .scopy-link__label,
          a.scopy-link--file-resolvable:hover .scopy-link__label {
            text-decoration: underline;
            text-underline-offset: 2px;
          }
          a.scopy-link--external .scopy-icon--external-link {
            width: 0.75em;
            height: 0.75em;
            margin-inline-start: 0.16em;
            vertical-align: -0.01em;
          }
          a.scopy-link--file {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            max-width: 100%;
            vertical-align: -0.16em;
          }
          a.scopy-link--file .scopy-file-icon {
            width: 1em;
            height: 1em;
            /* Phosphor glyphs keep ~13% grid padding inside their 256 viewBox; scaling the whole
               svg element (no internal clipping) restores the full-bleed optical size of the
               Codex reference file icons without editing licensed path data. */
            transform: scale(1.15);
          }
          a.scopy-link--file .scopy-link__label {
            min-width: 0;
            overflow-wrap: anywhere;
          }
          a.scopy-link--file-inert,
          a.scopy-link--inert,
          a.scopy-link--plugin {
            pointer-events: none;
          }
          a.scopy-link--file-inert {
            cursor: default;
          }
          html.scopy-export-mode a {
            pointer-events: none;
          }
          a.scopy-source-citation-link {
            display: inline-flex;
            align-items: center;
            pointer-events: auto;
            gap: 4px;
            max-width: none;
            height: calc(18px * var(--scopy-chatgpt-layout-font-scale));
            min-height: calc(18px * var(--scopy-chatgpt-layout-font-scale));
            padding: 0 8px 0 4px;
            margin-inline-start: 4px;
            position: relative;
            border-radius: 12px;
            overflow: visible;
            color: rgb(93, 93, 93);
            background: rgb(244, 244, 244);
            font-size: calc(9px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(18px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 400;
            text-align: center;
            text-decoration: none;
            white-space: nowrap;
            vertical-align: middle;
            cursor: pointer;
          }
          a.scopy-source-citation-link::after {
            content: none;
          }
          .scopy-source-citation-group {
            display: inline-flex;
            align-items: center;
            position: relative;
            margin-inline-start: 4px;
            line-height: 1;
            vertical-align: -0.12em;
          }
          .scopy-source-citation-group > a.scopy-source-citation-link {
            margin-inline-start: 0;
          }
          .scopy-source-citation-favicon-fallback,
          .scopy-source-citation-origin-icon {
            flex: 0 0 auto;
            width: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            height: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            color: rgb(93, 93, 93);
          }
          img.scopy-source-citation-favicon {
            border-radius: 3px;
            object-fit: contain;
          }
          .scopy-source-citation-label {
            max-width: 15ch;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
          }
          .scopy-source-citation-count {
            flex: 0 0 auto;
            color: rgb(143, 143, 143);
            font-size: calc(9px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(18px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-source-citation-supporting {
            display: none;
            position: absolute;
            z-index: 20;
            inset-block-start: calc(100% - 1px);
            inset-inline-start: auto;
            inset-inline-end: auto;
            left: var(--scopy-source-popup-left, 0px);
            width: min(320px, var(--scopy-source-popup-max-width, calc(100vw - 24px)));
            min-width: min(200px, var(--scopy-source-popup-max-width, calc(100vw - 24px)));
            max-width: var(--scopy-chatgpt-thread-content-width);
            padding: 6px;
            border: 1px solid var(--scopy-border-subtle);
            border-radius: 12px;
            color: var(--scopy-text-primary);
            background: var(--scopy-page-bg);
            box-shadow: 0 8px 24px rgba(13, 13, 13, 0.12);
          }
          .scopy-source-citation-group:hover .scopy-source-citation-supporting,
          .scopy-source-citation-group:focus-within .scopy-source-citation-supporting {
            display: grid;
            gap: 2px;
          }
          .scopy-source-citation-supporting-item {
            display: block;
          }
          a.scopy-source-citation-supporting-link {
            display: flex;
            align-items: center;
            pointer-events: auto;
            gap: 6px;
            min-width: 0;
            padding: 6px 8px;
            border-radius: 8px;
            color: var(--scopy-text-primary);
            font-size: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(18px * var(--scopy-chatgpt-layout-font-scale));
            text-decoration: none;
            cursor: pointer;
          }
          a.scopy-source-citation-supporting-link:hover {
            background: rgb(244, 244, 244);
          }
          a.scopy-source-citation-link:focus-visible,
          a.scopy-source-citation-supporting-link:focus-visible,
          a.scopy-link:focus-visible,
          .scopy-rich button:focus-visible,
          .scopy-rich input:focus-visible,
          .scopy-rich a:focus-visible,
          .footnote-ref a:focus-visible,
          a[data-footnote-ref]:focus-visible,
          .footnote-backref:focus-visible,
          a[data-footnote-backref]:focus-visible {
            outline: 2px solid rgb(10, 132, 255);
            outline-offset: 2px;
            border-radius: 3px;
          }
          a.scopy-source-citation-supporting-link::after {
            content: none;
          }
          html.scopy-export-mode .scopy-source-citation-supporting {
            display: none;
          }
          .scopy-visually-hidden {
            position: absolute !important;
            width: 1px !important;
            height: 1px !important;
            padding: 0 !important;
            margin: -1px !important;
            overflow: hidden !important;
            clip: rect(0, 0, 0, 0) !important;
            white-space: nowrap !important;
            border: 0 !important;
          }
          #content > .scopy-rich {
            width: min(var(--scopy-chatgpt-thread-content-max-width), calc(var(--scopy-chatgpt-render-width) - (var(--scopy-chatgpt-content-inline-padding) * 2)));
            max-width: min(var(--scopy-chatgpt-thread-content-max-width), calc(var(--scopy-chatgpt-render-width) - (var(--scopy-chatgpt-content-inline-padding) * 2)));
          }
          .scopy-rich {
            display: block;
            margin: 16px 0;
            padding: 0;
            border: 0;
            border-radius: 0;
            position: relative;
            overflow: visible;
            color: var(--scopy-text-primary);
            background: transparent;
            font-family: var(--scopy-chatgpt-font);
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-body-line-height);
            container-type: inline-size;
          }
          .scopy-rich[data-state="partial"] {
            opacity: 0.92;
          }
          .scopy-rich[data-state="empty"],
          .scopy-rich[data-state="error"] {
            padding: 16px 20px;
            border: 1px solid var(--scopy-rich-border);
            border-radius: 16px;
            background: var(--scopy-surface-bg);
          }
          .scopy-rich-state-message,
          .scopy-rich-boundary {
            margin: 0 0 8px;
            color: var(--scopy-text-secondary);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich button,
          .scopy-rich input {
            font-family: inherit;
          }
          .scopy-rich button {
            appearance: none;
            border: 0;
            color: inherit;
            background: transparent;
          }
          .scopy-rich-web-results {
            display: grid;
            gap: 16px;
            margin: 0;
            padding: 0;
            list-style: none;
          }
          .scopy-rich-web-result {
            min-height: 0;
            margin: 0;
            padding: 0;
            list-style: none;
          }
          .scopy-rich-web-result-source {
            display: flex;
            align-items: center;
            gap: 8px;
            margin: 0;
            color: var(--scopy-text-secondary);
            font-size: calc(13px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-web-result-source time::before {
            content: "·";
            margin-inline: 2px 8px;
          }
          .scopy-rich-web-result-title {
            margin: 2px 0 0;
            font-size: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
          }
          .scopy-rich-web-result-link {
            color: var(--scopy-link-color);
          }
          .scopy-rich-web-result-snippet {
            margin: 2px 0 0;
            color: var(--scopy-text-primary);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(22px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-origin-icon {
            width: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            height: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            border-radius: 50%;
          }
          .scopy-rich-news-track {
            display: flex;
            gap: var(--scopy-rich-column-gap);
            width: 100%;
            margin: 0;
            padding: 8px 0;
            overflow-x: auto;
            overscroll-behavior-inline: contain;
            scroll-snap-type: inline proximity;
            list-style: none;
            scrollbar-width: none;
          }
          .scopy-rich-news-item {
            display: flex;
            flex: 0 0 min(var(--scopy-rich-news-card-ideal-width), calc(100% - 24px));
            min-height: 0;
            margin: 0;
            padding: 0;
            scroll-snap-align: start;
            list-style: none;
          }
          .scopy-rich-news-card {
            width: 100%;
            overflow: hidden;
            border: 1px solid var(--scopy-rich-border-strong);
            border-radius: 12px;
            background: var(--scopy-surface-bg);
          }
          .scopy-rich-news-link {
            display: flex;
            height: 100%;
            gap: 16px;
            padding-bottom: 24px;
            flex-direction: column;
            color: var(--scopy-text-primary);
          }
          .scopy-rich-news-media {
            display: block;
            width: 100%;
            height: 144px;
            flex: 0 0 144px;
            border: 0;
            border-radius: 0;
            object-fit: cover;
          }
          .scopy-rich-news-body {
            display: flex;
            min-width: 0;
            padding: 0 16px;
            gap: 8px;
            flex: 1 1 auto;
            flex-direction: column;
            overflow: hidden;
          }
          .scopy-rich-news-source {
            display: flex;
            align-items: center;
            gap: 6px;
            color: var(--scopy-text-primary);
            font-size: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(16px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-news-source .scopy-rich-origin-icon {
            width: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            height: calc(12px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-news-title {
            display: -webkit-box;
            margin: 0;
            overflow: hidden;
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
            -webkit-box-orient: vertical;
            -webkit-line-clamp: 5;
          }
          .scopy-rich-news-date {
            display: block;
            margin: 0;
            color: var(--scopy-text-secondary);
            font-size: calc(12px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(16px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-image-grid {
            display: flex;
            width: 100%;
            min-width: 0;
            min-height: 144px;
            gap: var(--scopy-rich-image-gap);
            margin: 4px 0 20px;
            overflow-x: auto;
            overscroll-behavior-inline: contain;
            scrollbar-width: none;
          }
          .scopy-rich-image-layout-search {
            flex-flow: row nowrap;
          }
          .scopy-rich-image-layout-carousel {
            flex-flow: row nowrap;
          }
          .scopy-rich-image-layout-full_width {
            display: block;
          }
          .scopy-rich-image-item {
            flex: 0 0 128px;
            min-width: 0;
            margin: 0;
            aspect-ratio: 5 / 4;
            overflow: hidden;
            border: 1px solid var(--scopy-rich-border-strong);
            border-radius: 12px;
            background: rgb(244, 244, 244);
          }
          .scopy-rich-image-layout-full_width .scopy-rich-image-item {
            width: 100%;
          }
          @container (min-width: 24.5rem) {
            .scopy-rich-image-layout-search,
            .scopy-rich-image-layout-carousel {
              overflow-x: hidden;
            }
            .scopy-rich-image-layout-search .scopy-rich-image-item,
            .scopy-rich-image-layout-carousel .scopy-rich-image-item {
              flex-basis: calc((100% - (var(--scopy-rich-image-gap) * 2)) / 3);
            }
          }
          @container (min-width: 48rem) {
            .scopy-rich-news-item {
              flex-basis: calc((100% - (var(--scopy-rich-column-gap) * 2)) / 3);
            }
          }
          .scopy-rich-image-button {
            display: block;
            width: 100%;
            height: 100%;
            padding: 0;
            cursor: zoom-in;
          }
          .scopy-rich-image,
          .scopy-rich-image-placeholder {
            display: flex;
            width: 100%;
            height: 100%;
            align-items: center;
            justify-content: center;
            border: 0;
            border-radius: 0;
            color: var(--scopy-text-secondary);
            background: rgb(244, 244, 244);
            font-size: calc(13px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            text-align: center;
          }
          img.scopy-rich-image {
            object-fit: cover;
          }
          .scopy-rich-lightbox {
            position: fixed;
            z-index: 1000;
            inset: 0;
            width: 100vw;
            height: 100vh;
            color: #ffffff;
            background: rgba(0, 0, 0, 0.96);
          }
          .scopy-rich-lightbox-stage {
            position: absolute;
            inset: clamp(48px, 7vh, 56px) clamp(48px, 8vw, 72px) clamp(72px, 10vh, 86px);
            display: flex;
            align-items: center;
            justify-content: center;
          }
          .scopy-rich-lightbox-image {
            display: block;
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
          }
          .scopy-rich-lightbox-close,
          .scopy-rich-lightbox-previous,
          .scopy-rich-lightbox-next {
            position: absolute;
            z-index: 2;
            display: grid;
            width: 40px;
            height: 40px;
            padding: 0;
            place-items: center;
            border-radius: 999px;
            color: #ffffff;
            background: rgba(255, 255, 255, 0.12);
            cursor: pointer;
          }
          .scopy-rich-lightbox-close { top: 16px; right: 16px; }
          .scopy-rich-lightbox-previous { top: 50%; left: 16px; transform: translateY(-50%); }
          .scopy-rich-lightbox-next { top: 50%; right: 16px; transform: translateY(-50%); }
          .scopy-rich-lightbox-counter {
            position: absolute;
            top: 16px;
            left: 20px;
            margin: 0;
            color: #ffffff;
            font-size: 14px;
            line-height: 40px;
          }
          .scopy-rich-lightbox-meta {
            position: absolute;
            right: clamp(48px, 8vw, 72px);
            bottom: clamp(14px, 3vh, 22px);
            left: clamp(48px, 8vw, 72px);
            text-align: center;
          }
          .scopy-rich-lightbox-meta p {
            margin: 0;
            color: #ffffff;
            font-size: 14px;
            line-height: 20px;
          }
          .scopy-rich-lightbox-meta p:first-child {
            color: rgba(255, 255, 255, 0.65);
          }
          .scopy-rich-weather-card,
          .scopy-rich-finance-card,
          .scopy-rich-currency-card {
            width: 100%;
            overflow: hidden;
            border: 1px solid var(--scopy-rich-border);
            border-radius: var(--scopy-rich-card-radius);
            background: var(--scopy-surface-bg);
          }
          .scopy-rich-weather-card {
            padding: var(--scopy-rich-card-padding) var(--scopy-rich-card-padding) 12px;
          }
          .scopy-rich-weather-location {
            margin: 0;
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
          }
          .scopy-rich-weather-current-panel {
            margin-top: 20px;
          }
          .scopy-rich-weather-current-row {
            display: flex;
            align-items: flex-start;
          }
          .scopy-rich-weather-current-value {
            margin: 0;
            font-size: calc(48px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(48px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
            letter-spacing: -0.02em;
          }
          .scopy-rich-weather-unit {
            display: flex;
            margin: 2px 0 0 8px;
            color: var(--scopy-text-weak);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-weather-unit-option {
            padding: 0 2px;
            color: var(--scopy-text-weak);
            cursor: pointer;
          }
          .scopy-rich-weather-unit-option[aria-pressed="true"] {
            color: var(--scopy-text-primary);
            font-weight: 600;
          }
          .scopy-rich-weather-summary {
            margin: 12px 0 0;
            font-size: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(26px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-weather-days {
            display: flex;
            width: auto;
            height: 122px;
            margin: 22px calc(-1 * var(--scopy-rich-card-padding)) 0;
            padding: 0 var(--scopy-rich-card-padding);
            overflow-x: auto;
            overscroll-behavior-inline: contain;
            scrollbar-width: none;
          }
          .scopy-rich-weather-day {
            display: grid;
            grid-template-rows: 20px 28px 26px 20px;
            row-gap: 4px;
            flex: 1 0 90px;
            min-width: 90px;
            height: 122px;
            padding: 8px;
            justify-items: center;
            border-radius: var(--scopy-rich-control-radius);
            text-align: center;
            cursor: pointer;
          }
          .scopy-rich-weather-day[aria-selected="true"] {
            background: rgba(140, 195, 235, 0.13);
          }
          .scopy-rich-weather-day-name {
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
          }
          .scopy-rich-weather-day-icon,
          .scopy-rich-weather-day-icon-placeholder {
            display: block;
            width: 28px;
            height: 28px;
            object-fit: contain;
          }
          .scopy-rich-weather-day-high {
            font-size: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(26px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 600;
          }
          .scopy-rich-weather-day-low {
            color: var(--scopy-text-weak);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-weather-chart-title {
            display: flex;
            width: auto;
            height: 28px;
            margin: 20px calc(-1 * var(--scopy-rich-card-padding)) 0;
            padding: 0 12px;
            align-items: center;
            gap: 8px;
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(28px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
          }
          .scopy-rich-weather-chart-title .scopy-icon {
            width: 7px;
            height: 11px;
            color: var(--scopy-text-weak);
          }
          .scopy-rich-weather-chart {
            position: relative;
            width: auto;
            height: 128px;
            /* currentColor feeds the SVG gradient stops; line/label colors stay explicit. */
            color: var(--scopy-rich-weather-chart-warm);
            margin: 8px calc(-1 * var(--scopy-rich-card-padding)) 0;
            padding-bottom: 8px;
            overflow-x: auto;
            overflow-y: hidden;
            overscroll-behavior-inline: contain;
            scrollbar-width: none;
          }
          .scopy-rich-weather-chart svg {
            display: block;
            width: auto;
            min-width: 100%;
            max-width: none;
            height: 120px;
          }
          .scopy-rich-weather-chart-line {
            stroke: rgb(17, 17, 17);
            stroke-width: 2;
            stroke-linecap: round;
            stroke-linejoin: round;
          }
          .scopy-rich-chart-dot {
            fill: rgb(17, 17, 17);
            stroke: #ffffff;
            stroke-width: 2;
          }
          .scopy-rich-weather-chart-value {
            fill: var(--scopy-text-primary);
            font-size: 14px;
            font-weight: 600;
          }
          .scopy-rich-weather-chart-time {
            fill: var(--scopy-text-secondary);
            font-size: 12px;
          }
          .scopy-rich-finance-card {
            padding: 0;
          }
          .scopy-rich-finance-header {
            padding: 20px 20px 12px;
            border-bottom: 1px solid var(--scopy-rich-border);
          }
          .scopy-rich-finance-asset {
            margin: 0;
            color: var(--scopy-text-secondary);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-finance-price {
            margin: 4px 0 0;
            font-size: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(32px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
          }
          .scopy-rich-finance-summary {
            margin-top: 4px;
          }
          .scopy-rich-finance-summary p,
          .scopy-rich-finance-after-hours {
            margin: 0;
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-finance-change,
          .scopy-rich-finance-after-hours {
            font-weight: 500;
          }
          .scopy-rich-finance-date-range,
          .scopy-rich-finance-after-hours {
            margin-top: 4px;
          }
          .scopy-rich-finance-date-range,
          .scopy-rich-finance-after-hours-label {
            color: var(--scopy-text-secondary);
            font-weight: 400;
          }
          .scopy-rich-trend-up .scopy-rich-finance-change,
          .scopy-rich-trend-up.scopy-rich-finance-after-hours {
            color: var(--scopy-rich-trend-up-text);
          }
          .scopy-rich-trend-down .scopy-rich-finance-change,
          .scopy-rich-trend-down.scopy-rich-finance-after-hours {
            color: var(--scopy-rich-trend-down);
          }
          .scopy-rich-trend-flat .scopy-rich-finance-change,
          .scopy-rich-trend-flat.scopy-rich-finance-after-hours {
            color: var(--scopy-text-secondary);
          }
          .scopy-rich-finance-after-hours-price {
            color: var(--scopy-text-primary);
            font-weight: 500;
          }
          .scopy-rich-finance-chart.scopy-rich-trend-up { color: var(--scopy-rich-trend-up-stroke); }
          .scopy-rich-finance-chart.scopy-rich-trend-down { color: var(--scopy-rich-trend-down); }
          .scopy-rich-finance-chart.scopy-rich-trend-flat { color: var(--scopy-text-secondary); }
          .scopy-rich-finance-ranges {
            display: grid;
            grid-auto-flow: column;
            grid-auto-columns: minmax(var(--scopy-rich-range-min-width), 1fr);
            width: 100%;
            max-width: 100%;
            height: 32px;
            gap: 2px;
            margin-top: 20px;
            padding: 2px 20px;
            overflow-x: auto;
            overscroll-behavior-inline: contain;
            scrollbar-width: none;
          }
          .scopy-rich-finance-range {
            position: relative;
            width: 100%;
            height: 28px;
            padding: 0 8px;
            border-radius: 999px;
            color: var(--scopy-text-weak);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 600;
            cursor: pointer;
          }
          .scopy-rich-finance-range[aria-checked="true"] {
            color: var(--scopy-text-primary);
            background: rgb(244, 244, 244);
          }
          .scopy-rich-finance-chart {
            position: relative;
            width: 100%;
            height: clamp(200px, 31.25cqi, 240px);
            margin: 0;
            overflow: visible;
          }
          .scopy-rich-finance-charts {
            margin: 16px 8px 0 20px;
          }
          .scopy-rich-finance-chart svg {
            display: block;
            width: 100%;
            height: 100%;
          }
          .scopy-rich-finance-grid-line {
            stroke: rgb(226, 226, 226);
            stroke-width: 1;
            stroke-dasharray: 3 4;
          }
          .scopy-rich-finance-chart-line {
            stroke: currentColor;
            stroke-width: 2;
            stroke-linecap: round;
            stroke-linejoin: round;
          }
          .scopy-rich-finance-axis-label {
            fill: var(--scopy-text-secondary);
            font-size: 12px;
          }
          .scopy-rich-finance-hit-point {
            fill: transparent;
            stroke: transparent;
          }
          .scopy-rich-chart-tooltip {
            position: absolute;
            z-index: 4;
            top: 12px;
            left: 50%;
            display: flex;
            gap: 8px;
            padding: 8px 12px;
            border: 1px solid var(--scopy-rich-border);
            border-radius: 10px;
            color: var(--scopy-text-primary);
            background: var(--scopy-surface-bg);
            box-shadow: 0 4px 16px rgba(13, 13, 13, 0.12);
            font-size: 13px;
            line-height: 18px;
            transform: translateX(-50%);
            max-width: calc(100% - 24px);
            white-space: normal;
            pointer-events: none;
          }
          .scopy-rich-finance-metrics {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(min(12rem, 100%), 1fr));
            gap: 8px 32px;
            margin: 16px 20px 20px;
          }
          .scopy-rich-finance-metrics > div {
            display: flex;
            min-width: 0;
            align-items: baseline;
            justify-content: space-between;
            gap: 2px;
          }
          .scopy-rich-finance-metrics dt,
          .scopy-rich-finance-metrics dd {
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-finance-metrics dt {
            color: var(--scopy-text-secondary);
          }
          .scopy-rich-finance-metrics dd {
            margin: 0;
            text-align: end;
          }
          @container (max-width: 32rem) {
            .scopy-rich-weather-day {
              flex-grow: 0;
            }
            .scopy-rich-finance-metrics {
              grid-template-columns: minmax(0, 1fr);
            }
          }
          .scopy-rich-currency-card {
            min-height: 199px;
            display: grid;
            grid-template-rows: repeat(2, minmax(0, 1fr));
          }
          .scopy-rich-currency-row {
            position: relative;
            display: flex;
            min-width: 0;
            padding: 0 20px;
            flex-direction: column;
            justify-content: center;
            gap: 4px;
          }
          .scopy-rich-currency-row + .scopy-rich-currency-row::before {
            content: "";
            position: absolute;
            top: 0;
            right: 20px;
            left: 20px;
            height: 1px;
            background: var(--scopy-rich-border);
          }
          .scopy-rich-currency-label {
            display: flex;
            align-items: center;
            gap: 8px;
            color: var(--scopy-text-secondary);
            font-size: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(20px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-currency-flag {
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-currency-value {
            display: flex;
            min-width: 0;
            align-items: baseline;
          }
          .scopy-rich-currency-symbol {
            margin-inline-end: 4px;
            color: var(--scopy-text-secondary);
            font-size: calc(18px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(32px * var(--scopy-chatgpt-layout-font-scale));
          }
          .scopy-rich-currency-input {
            min-width: 0;
            width: min(18ch, calc(100% - 28px));
            margin: 0;
            padding: 0;
            border: 0;
            outline: 0;
            color: var(--scopy-text-primary);
            background: transparent;
            font-size: calc(24px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(32px * var(--scopy-chatgpt-layout-font-scale));
            font-weight: 500;
            font-variant-numeric: tabular-nums;
            direction: ltr;
            unicode-bidi: isolate;
          }
          .scopy-rich-currency-input[aria-invalid="true"] {
            color: var(--scopy-rich-trend-down);
          }
          html.scopy-export-mode .scopy-rich-lightbox,
          html.scopy-export-mode .scopy-rich-chart-tooltip {
            display: none !important;
          }
          html.scopy-export-mode .scopy-rich button,
          html.scopy-export-mode .scopy-rich input {
            pointer-events: none;
          }
          blockquote {
            position: relative;
            margin: 0 0 8px 0;
            padding-block: 8px;
            padding-inline: 0;
            padding-inline-start: 24px;
            border: 0;
            color: var(--scopy-text-primary);
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-quote-line-height);
            font-weight: 400;
          }
          blockquote::after {
            content: "";
            display: block;
            position: absolute;
            inset-inline-start: 0;
            top: 8px;
            bottom: 8px;
            width: 4px;
            background-color: var(--scopy-border);
            border-radius: 2px;
          }
          blockquote > p {
            margin-top: 0;
            margin-bottom: 0;
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-quote-line-height);
            font-weight: 400;
          }
          blockquote ul,
          blockquote ol {
            margin-top: 0;
            margin-bottom: 0;
            padding-inline-start: 26px;
            font-size: var(--scopy-chatgpt-body-font-size);
            line-height: var(--scopy-chatgpt-quote-line-height);
            font-weight: 400;
          }
          hr {
            border: 0;
            border-top: 1px solid var(--scopy-border);
            margin: 28px 0;
          }
          .scopy-math-host {
            direction: ltr;
            unicode-bidi: isolate;
          }
          .scopy-math-inline-host {
            display: inline-block;
            max-width: 100%;
            overflow-x: auto;
            overflow-y: hidden;
            white-space: nowrap;
          }
          .scopy-math-display-host {
            display: block;
            max-width: 100%;
          }
          .katex {
            color: var(--scopy-text-primary);
            font-size: 1.21em;
            line-height: 1.2;
            direction: ltr;
            unicode-bidi: isolate;
          }
          .katex-display {
            display: block;
            max-width: 100%;
            overflow-x: auto;
            overflow-y: hidden;
            margin: 16px 0;
            text-align: center;
            white-space: nowrap;
          }
          .scopy-chatgpt-table-container {
            display: block;
            overflow-x: auto;
            overflow-y: hidden;
            margin-block: 0;
            margin-inline: calc(-1 * var(--scopy-chatgpt-content-inline-padding));
            padding-inline: var(--scopy-chatgpt-content-inline-padding);
            width: var(--scopy-chatgpt-render-width);
            max-width: none;
            box-sizing: border-box;
            -webkit-overflow-scrolling: touch;
            scrollbar-width: none;
          }
          .scopy-chatgpt-table-wrapper {
            width: fit-content;
            min-width: var(--scopy-chatgpt-thread-content-width);
            margin-inline: auto;
          }
          table {
            display: table;
            border-collapse: separate;
            border-spacing: 0;
            min-width: var(--scopy-chatgpt-thread-content-width);
            width: fit-content;
            max-width: none;
            table-layout: auto;
            overflow: visible;
            border: 0;
            margin: 0;
            font-family: var(--scopy-chatgpt-font);
            font-size: calc(14px * var(--scopy-chatgpt-layout-font-scale));
            line-height: calc(24px * var(--scopy-chatgpt-layout-font-scale));
          }
          th, td {
            border: 0;
            padding-inline: 0;
            text-align: start;
            white-space: normal;
            word-break: normal;
            overflow-wrap: anywhere;
          }
          th:not(:last-child),
          td:not(:last-child) {
            padding-inline-end: 24px;
          }
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] th[data-col-size="sm"],
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] td[data-col-size="sm"] {
            min-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 4 / 24);
            max-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 6 / 24);
          }
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] th[data-col-size="md"],
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] td[data-col-size="md"] {
            min-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 6 / 24);
            max-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 8 / 24);
          }
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] th[data-col-size="lg"],
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] td[data-col-size="lg"] {
            min-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 8 / 24);
            max-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 12 / 24);
          }
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] th[data-col-size="xl"],
          .scopy-chatgpt-table-container[data-scopy-table-model="markdown-pipe"] td[data-col-size="xl"] {
            min-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 14 / 24);
            max-width: calc(var(--scopy-chatgpt-markdown-table-col-baseline) * 18 / 24);
          }
          thead th {
            border-bottom: 1px solid var(--scopy-border);
            color: var(--scopy-text-primary);
            font-weight: 600;
            line-height: calc(16px * var(--scopy-chatgpt-layout-font-scale));
            padding-block: 8px;
            vertical-align: bottom;
          }
          tbody td {
            border-bottom: 1px solid var(--scopy-border-subtle);
          }
          tbody tr:last-child td {
            border-bottom: 0;
            padding-bottom: 24px;
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
          \(taskListStyle)\(footnoteStyle)
          /* Hide scrollbars inside HTML when idle (even if system setting is "always show scroll bars").
             We show them temporarily while the user is actively scrolling overflow containers (JS toggles the class). */
          pre::-webkit-scrollbar,
          .scopy-chatgpt-table-container::-webkit-scrollbar,
          table::-webkit-scrollbar,
          .scopy-math-inline-host::-webkit-scrollbar,
          .katex-display::-webkit-scrollbar,
          .footnotes::-webkit-scrollbar,
          details::-webkit-scrollbar {
            width: 0px;
            height: 0px;
          }
          html.scopy-scrollbars-visible pre::-webkit-scrollbar,
          html.scopy-scrollbars-visible .scopy-chatgpt-table-container::-webkit-scrollbar,
          html.scopy-scrollbars-visible table::-webkit-scrollbar,
          html.scopy-scrollbars-visible .scopy-math-inline-host::-webkit-scrollbar,
          html.scopy-scrollbars-visible .katex-display::-webkit-scrollbar,
          html.scopy-scrollbars-visible .footnotes::-webkit-scrollbar,
          html.scopy-scrollbars-visible details::-webkit-scrollbar {
            width: 8px;
            height: 8px;
          }
        </style>
        """
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

    static func document(markdown: String, context: MarkdownRenderContext) -> String {
        let markdownLiteral = jsonLiteral(markdown)
        let policyLiteral = jsonLiteral(unifiedPolicyPayload(context: context))
        let overflowSelectorLiteral = jsonStringLiteral(overflowProbeSelector)
        let taskListBootstrapScript = MarkdownTaskListRuntime.bootstrapScript

        return """
        <!doctype html>
        <html data-scopy-render-id="\(MarkdownPreviewRenderIdentity.placeholder)">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            \(cspMetaTag)
            <link id="scopy-katex-stylesheet" rel="stylesheet" href="katex.min.css">
            <script defer src="contrib/scopy-unified-renderer.iife.js"></script>
            \(baseStyle(layoutScale: context.layoutScale))
            \(taskListBootstrapScript)
            <script>
              (function () {
                window.__scopyRenderState = window.__scopyRenderState || {
                  renderComplete: false,
                  markdownRendered: false,
                  renderFailed: false,
                  unifiedRenderSucceeded: false,
                  renderPass: 0,
                  stylesheetReady: false,
                  fontsReady: false,
                  imagesReady: false,
                  paintReady: false,
                  layoutEpoch: 0,
                  hydrationWarning: ''
                };
                var lastH = 0;
                var lastW = 0;
                var lastOverflowX = false;
                var lastRenderSucceeded = false;
                var lastRenderErrorReason = '';
                var unifiedRenderAttempts = 0;
                var maxUnifiedRenderAttempts = 100;
                var pendingHeightReportHandle = 0;
                var pendingHeightReportForce = false;
                var layoutObserver = null;
                function currentRenderGeneration() {
                  try { return document.documentElement.getAttribute('data-scopy-render-id') || ''; } catch (e) { return ''; }
                }
                window.__scopyIsRenderReady = function () {
                  try {
                    var state = window.__scopyRenderState || {};
                    return !!state.renderComplete && !!state.markdownRendered &&
                      !!state.stylesheetReady && !!state.fontsReady && !!state.imagesReady && !!state.paintReady &&
                      !state.renderFailed && state.unifiedRenderSucceeded !== false;
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
                function reportHeightNow(force) {
                  try {
                    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopySize) { return; }
                    var el = document.getElementById('content');
                    if (!el) { return; }
                    var state = window.__scopyRenderState || {};
                    if (!state.renderComplete) { return; }
                    layoutChatGPTTables(el);
                    updateChatGPTPreviewScale(el);
                    var box = document.getElementById('content-scale-shell') || el;
                    var rect = box.getBoundingClientRect();
                    var w = Math.ceil(rect.width || 0);
                    var h = Math.ceil(rect.height || 0);
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
                    var renderSucceeded = !state.renderFailed && !!state.markdownRendered && state.unifiedRenderSucceeded !== false;
                    var renderErrorReason = state.unifiedErrorReason || '';
                    if (!force &&
                        Math.abs(h - lastH) < 1 &&
                        Math.abs(w - lastW) < 1 &&
                        overflowX === lastOverflowX &&
                        renderSucceeded === lastRenderSucceeded &&
                        renderErrorReason === lastRenderErrorReason) { return; }
                    lastH = h;
                    lastW = w;
                    lastOverflowX = overflowX;
                    lastRenderSucceeded = renderSucceeded;
                    lastRenderErrorReason = renderErrorReason;
                    window.webkit.messageHandlers.scopySize.postMessage({
                      renderID: document.documentElement.getAttribute('data-scopy-render-id') || '',
                      width: w,
                      height: h,
                      overflowX: overflowX,
                      renderSucceeded: renderSucceeded,
                      renderErrorReason: renderErrorReason
                    });
                  } catch (e) { }
                }
                window.__scopyReportHeight = function (force) {
                  pendingHeightReportForce = pendingHeightReportForce || !!force;
                  if (pendingHeightReportHandle) { return; }
                  var scheduledGeneration = currentRenderGeneration();
                  var deliver = function () {
                    pendingHeightReportHandle = 0;
                    var shouldForce = pendingHeightReportForce;
                    pendingHeightReportForce = false;
                    if (currentRenderGeneration() !== scheduledGeneration) { return; }
                    reportHeightNow(shouldForce);
                  };
                  if (typeof window.requestAnimationFrame === 'function') {
                    pendingHeightReportHandle = window.requestAnimationFrame(deliver);
                  } else {
                    pendingHeightReportHandle = window.setTimeout(deliver, 0);
                  }
                };
                function installGenerationScopedLayoutObserver() {
                  var el = document.getElementById('content');
                  if (!el || layoutObserver) { return; }
                  var observedGeneration = currentRenderGeneration();
                  if (typeof window.ResizeObserver === 'function') {
                    layoutObserver = new window.ResizeObserver(function () {
                      if (currentRenderGeneration() !== observedGeneration) { return; }
                      window.__scopyReportHeight(false);
                    });
                    layoutObserver.observe(el);
                  }
                  el.addEventListener('toggle', function (event) {
                    if (currentRenderGeneration() !== observedGeneration) { return; }
                    var target = event && event.target;
                    if (!target || String(target.tagName || '').toLowerCase() !== 'details') { return; }
                    window.__scopyReportHeight(true);
                  }, true);
                  el.addEventListener('keydown', function () {
                    if (currentRenderGeneration() !== observedGeneration) { return; }
                    window.__scopyReportHeight(true);
                  }, true);
                  try {
                    if (document.fonts && document.fonts.ready && typeof document.fonts.ready.then === 'function') {
                      document.fonts.ready.then(function () {
                        if (currentRenderGeneration() === observedGeneration) { window.__scopyReportHeight(true); }
                      });
                    }
                  } catch (e) { }
                }
                function replaceFailedImage(image) {
                  try {
                    if (!image || !image.parentNode) { return; }
                    var fallback = document.createElement('span');
                    var label = String(image.getAttribute('alt') || '').trim();
                    fallback.className = 'scopy-image-terminal-fallback';
                    fallback.setAttribute('role', 'img');
                    fallback.setAttribute('aria-label', label || '图片无法显示');
                    fallback.setAttribute('data-scopy-image-state', 'error');
                    fallback.textContent = label ? label + ' · 图片无法显示' : '图片无法显示';
                    image.parentNode.replaceChild(fallback, image);
                  } catch (e) { }
                }
                function settleRenderedImages(root, completion) {
                  var images = [];
                  try {
                    images = root && root.querySelectorAll ? Array.prototype.slice.call(root.querySelectorAll('img:not([data-scopy-deferred-image])')) : [];
                  } catch (e) {
                    images = [];
                  }
                  if (!images.length) {
                    completion();
                    return;
                  }
                  var remaining = images.length;
                  var completed = false;
                  var settled = [];
                  function finishAll() {
                    if (completed || remaining > 0) { return; }
                    completed = true;
                    completion();
                  }
                  function finishImage(image, succeeded) {
                    var index = images.indexOf(image);
                    if (index < 0 || settled[index]) { return; }
                    settled[index] = true;
                    remaining -= 1;
                    try {
                      image.setAttribute('data-scopy-image-state', succeeded ? 'ready' : 'error');
                    } catch (e) { }
                    if (!succeeded) { replaceFailedImage(image); }
                    finishAll();
                  }
                  for (var i = 0; i < images.length; i++) {
                    (function (image) {
                      try {
                        image.addEventListener('load', function () { finishImage(image, true); }, { once: true });
                        image.addEventListener('error', function () { finishImage(image, false); }, { once: true });
                        if (image.complete) {
                          setTimeout(function () { finishImage(image, (image.naturalWidth || 0) > 0); }, 0);
                        } else if (typeof image.decode === 'function') {
                          image.decode().then(
                            function () { finishImage(image, true); },
                            function () { finishImage(image, false); }
                          );
                        }
                      } catch (e) {
                        finishImage(image, false);
                      }
                    })(images[i]);
                  }
                  setTimeout(function () {
                    for (var i = 0; i < images.length; i++) {
                      if (!settled[i]) { finishImage(images[i], false); }
                    }
                  }, 1500);
                }
                function awaitStylesheetReady(completion) {
                  var link = document.getElementById('scopy-katex-stylesheet');
                  if (!link) {
                    completion('stylesheet missing');
                    return;
                  }
                  try {
                    if (link.sheet) {
                      completion('');
                      return;
                    }
                  } catch (e) { }
                  var settled = false;
                  var timer = 0;
                  function done(reason) {
                    if (settled) { return; }
                    settled = true;
                    if (timer) { clearTimeout(timer); }
                    try {
                      link.removeEventListener('load', loaded);
                      link.removeEventListener('error', failed);
                    } catch (e) { }
                    completion(reason || '');
                  }
                  function loaded() { done(''); }
                  function failed() { done('stylesheet failed'); }
                  link.addEventListener('load', loaded, { once: true });
                  link.addEventListener('error', failed, { once: true });
                  timer = setTimeout(function () { done('stylesheet timeout'); }, 2500);
                }
                function awaitFontsReady(completion) {
                  function failedKatexFaceReason() {
                    try {
                      if (!document.fonts || typeof document.fonts.forEach !== 'function') { return ''; }
                      var reason = '';
                      document.fonts.forEach(function (face) {
                        if (reason || !face) { return; }
                        var family = String(face.family || '').replace(/["']/g, '');
                        if (family.indexOf('KaTeX_') === 0 && face.status === 'error') {
                          reason = 'KaTeX font failed: ' + family;
                        }
                      });
                      return reason;
                    } catch (e) {
                      return 'font verification failed';
                    }
                  }
                  try {
                    if (!document.fonts || !document.fonts.ready || typeof document.fonts.ready.then !== 'function') {
                      completion('');
                      return;
                    }
                    var settled = false;
                    var timer = setTimeout(function () {
                      if (settled) { return; }
                      settled = true;
                      completion('font timeout');
                    }, 3000);
                    document.fonts.ready.then(function () {
                      if (settled) { return; }
                      settled = true;
                      clearTimeout(timer);
                      completion(failedKatexFaceReason());
                    }, function () {
                      if (settled) { return; }
                      settled = true;
                      clearTimeout(timer);
                      completion('font failed');
                    });
                  } catch (e) {
                    completion('font exception');
                  }
                }
                function awaitTwoPaintFrames(completion) {
                  var remaining = 2;
                  var settled = false;
                  var generation = currentRenderGeneration();
                  var watchdog = setTimeout(function () {
                    if (settled) { return; }
                    settled = true;
                    completion('paint timeout');
                  }, 1500);
                  function done(reason) {
                    if (settled) { return; }
                    settled = true;
                    clearTimeout(watchdog);
                    completion(reason || '');
                  }
                  function step() {
                    if (currentRenderGeneration() !== generation) {
                      done('stale paint generation');
                      return;
                    }
                    try {
                      var state = window.__scopyRenderState || {};
                      state.layoutEpoch = (state.layoutEpoch || 0) + 1;
                    } catch (e) { }
                    remaining -= 1;
                    if (remaining <= 0) {
                      done('');
                      return;
                    }
                    if (typeof window.requestAnimationFrame === 'function') {
                      window.requestAnimationFrame(step);
                    } else {
                      setTimeout(step, 16);
                    }
                  }
                  if (typeof window.requestAnimationFrame === 'function') {
                    window.requestAnimationFrame(step);
                  } else {
                    setTimeout(step, 16);
                  }
                }
                function awaitTerminalReadiness(root) {
                  var terminal = false;
                  var pending = 3;
                  function fail(reason) {
                    if (terminal) { return; }
                    terminal = true;
                    failUnifiedRender(reason);
                  }
                  function ready(kind) {
                    if (terminal) { return; }
                    var state = window.__scopyRenderState || {};
                    if (kind === 'images') { state.imagesReady = true; }
                    if (kind === 'stylesheet') { state.stylesheetReady = true; }
                    if (kind === 'fonts') { state.fontsReady = true; }
                    pending -= 1;
                    if (pending > 0) { return; }
                    layoutChatGPTTables(root);
                    updateChatGPTPreviewScale(root);
                    awaitTwoPaintFrames(function (paintError) {
                      if (terminal) { return; }
                      if (paintError) {
                        fail(paintError);
                        return;
                      }
                      terminal = true;
                      state.paintReady = true;
                      finish(true);
                    });
                  }
                  settleRenderedImages(root, function () {
                    ready('images');
                  });
                  awaitStylesheetReady(function (stylesheetError) {
                    if (stylesheetError) {
                      fail(stylesheetError);
                      return;
                    }
                    ready('stylesheet');
                  });
                  awaitFontsReady(function (fontError) {
                    if (fontError) {
                      fail(fontError);
                      return;
                    }
                    ready('fonts');
                  });
                }
                function finish(succeeded) {
                  var el = document.getElementById('content');
                  if (el) {
                    try { el.style.opacity = '1'; } catch (e) { }
                  }
                  try {
                    if (window.__scopyRenderState) {
                      window.__scopyRenderState.markdownRendered = !!succeeded;
                      window.__scopyRenderState.renderComplete = true;
                      if (!succeeded) { window.__scopyRenderState.paintReady = false; }
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
                      window.__scopyRenderState.stylesheetReady = false;
                      window.__scopyRenderState.fontsReady = false;
                      window.__scopyRenderState.imagesReady = false;
                      window.__scopyRenderState.paintReady = false;
                      window.__scopyRenderState.layoutEpoch = 0;
                      window.__scopyRenderState.hydrationWarning = '';
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
                  var result = null;
                  try {
                    result = window.ScopyUnifiedMarkdown.render(\(markdownLiteral), \(policyLiteral));
                  } catch (e) {
                    failUnifiedRender('unified render exception');
                    return;
                  }
                  if (!result || !result.html) {
                    failUnifiedRender('unified returned empty html');
                    return;
                  }
                  el.innerHTML = result.html;
                  if (window.__scopyRenderState) {
                    window.__scopyRenderState.unifiedRenderSucceeded = true;
                  }
                  try {
                    if (typeof window.__scopyApplyTaskLists === 'function') {
                      window.__scopyApplyTaskLists(el);
                    }
                  } catch (e) {
                    if (window.__scopyRenderState) { window.__scopyRenderState.hydrationWarning = 'task-list hydration failed'; }
                  }
                  try {
                    if (typeof window.ScopyUnifiedMarkdown.hydrateRich === 'function') {
                      var exportMode = !!(document.documentElement && document.documentElement.classList && document.documentElement.classList.contains('scopy-export-mode'));
                      window.ScopyUnifiedMarkdown.hydrateRich(el, { exportMode: exportMode });
                    }
                  } catch (e) {
                    if (window.__scopyRenderState) {
                      var priorWarning = window.__scopyRenderState.hydrationWarning || '';
                      window.__scopyRenderState.hydrationWarning = priorWarning ? priorWarning + '; rich hydration failed' : 'rich hydration failed';
                    }
                  }
                  layoutChatGPTTables(el);
                  awaitTerminalReadiness(el);
                }
                if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', function () {
                    installGenerationScopedLayoutObserver();
                    renderUnified();
                  });
                } else {
                  installGenerationScopedLayoutObserver();
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
            <div id="content-scale-shell"><div id="content" dir="auto"></div></div>
          </body>
        </html>
        """
    }

    private static func unifiedPolicyPayload(context: MarkdownRenderContext) -> [String: AnyEncodable] {
        [
            "profile": AnyEncodable(context.profile.rawValue),
            "allowLooseMathRepair": AnyEncodable(context.policy.allowLooseMathRepair),
            "policyVersion": AnyEncodable(MarkdownRenderContextResolver.rendererVersion)
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
