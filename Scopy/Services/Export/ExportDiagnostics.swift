import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

extension ExportCoordinator {
    func dumpTableMetricsIfRequested(webView: WKWebView) async {
        guard !didDumpTableMetrics else { return }
        guard let path = ProcessInfo.processInfo.environment["SCOPY_EXPORT_TABLE_METRICS_PATH"], !path.isEmpty else { return }

        let widthPoints = Double(viewportWidthPoints)
        let js = """
        (function() {
          try {
            var content = document.getElementById('content');
            if (!content) { return JSON.stringify({ hasContent: false, targetWidth: 0, tables: [] }); }

            var padL = 0, padR = 0;
            try {
              var cs = window.getComputedStyle(content);
              padL = parseFloat(cs.paddingLeft) || 0;
              padR = parseFloat(cs.paddingRight) || 0;
            } catch (e) { padL = 0; padR = 0; }
            var targetWidth = Math.max(1, Math.floor(\(widthPoints) - padL - padR));

            function parseScale(transform) {
              if (!transform || transform === 'none') { return 1; }
              // matrix(a, b, c, d, e, f) => scaleX ~= sqrt(a^2 + b^2)
              var m = transform.match(/matrix\\(([^)]+)\\)/);
              if (!m || !m[1]) { return 1; }
              var parts = m[1].split(',').map(function(x) { return parseFloat(x); });
              if (!parts || parts.length < 4) { return 1; }
              var a = parts[0], b = parts[1];
              var s = Math.sqrt((a * a) + (b * b));
              return (s && isFinite(s) && s > 0) ? s : 1;
            }

            var tables = content.querySelectorAll('table');
            var out = [];
            for (var i = 0; i < (tables.length || 0); i++) {
              var t = tables[i];
              if (!t) { continue; }
              var block = t;
              try {
                var directParent = t.parentElement;
                if (directParent && directParent.classList && directParent.classList.contains('scopy-chatgpt-table-wrapper')) {
                  var containerParent = directParent.parentElement;
                  if (containerParent && containerParent.classList && containerParent.classList.contains('scopy-chatgpt-table-container')) {
                    block = containerParent;
                  }
                } else if (directParent && directParent.classList && directParent.classList.contains('scopy-chatgpt-table-container')) {
                  block = directParent;
                }
              } catch (e) { block = t; }
              var rect = t.getBoundingClientRect();
              var w = Math.ceil(rect.width || 0);
              var sw = 0, cw = 0;
              try { sw = Math.ceil(t.scrollWidth || 0); } catch (e) { sw = 0; }
              try { cw = Math.ceil(t.clientWidth || 0); } catch (e) { cw = 0; }

              var wrapped = false;
              var wrapperW = 0;
              try {
                var p = block.parentElement;
                wrapped = !!(p && p.classList && p.classList.contains('scopy-export-table-wrapper'));
                if (wrapped) {
                  var pr = p.getBoundingClientRect();
                  wrapperW = Math.ceil(pr.width || 0);
                }
              } catch (e) { wrapped = false; wrapperW = 0; }

              var cols = 0;
              try {
                var row = t.querySelector('tr');
                if (row && row.children) { cols = row.children.length || 0; }
              } catch (e) { cols = 0; }

              var scale = 1;
              try {
                var tr = window.getComputedStyle(block).transform;
                scale = parseScale(tr);
                if (scale === 1) {
                  tr = window.getComputedStyle(t).transform;
                  scale = parseScale(tr);
                }
              } catch (e) { scale = 1; }

              out.push({
                index: i,
                cols: cols,
                width: w,
                scrollWidth: sw,
                clientWidth: cw,
                wrapped: wrapped,
                wrapperWidth: wrapperW,
                scale: scale,
                targetWidth: targetWidth
              });
            }

            var exportScale = 1;
            var usesTransform = false;
            try {
              exportScale = window.ScopyDocument.export.state.scale || 1;
              usesTransform = !!window.ScopyDocument.export.state.usesTransform;
            } catch (e) { exportScale = 1; usesTransform = false; }

            var contentRectW = 0, contentRectH = 0;
            try {
              var r = content.getBoundingClientRect();
              contentRectW = Math.ceil(r.width || 0);
              contentRectH = Math.ceil(r.height || 0);
            } catch (e) { contentRectW = 0; contentRectH = 0; }

            var contentScrollW = 0, contentOffsetW = 0;
            try { contentScrollW = Math.ceil(content.scrollWidth || 0); } catch (e) { contentScrollW = 0; }
            try { contentOffsetW = Math.ceil(content.offsetWidth || 0); } catch (e) { contentOffsetW = 0; }

            var contentComputedWidth = '', contentComputedMaxWidth = '', contentComputedTransform = '';
            try {
              var ccs = window.getComputedStyle(content);
              contentComputedWidth = ccs.width || '';
              contentComputedMaxWidth = ccs.maxWidth || '';
              contentComputedTransform = ccs.transform || '';
            } catch (e) { contentComputedWidth = ''; contentComputedMaxWidth = ''; contentComputedTransform = ''; }

            var contentStyleWidth = '', contentStyleMaxWidth = '', contentStyleTransform = '';
            try {
              contentStyleWidth = content.style && content.style.width ? content.style.width : '';
              contentStyleMaxWidth = content.style && content.style.maxWidth ? content.style.maxWidth : '';
              contentStyleTransform = content.style && content.style.transform ? content.style.transform : '';
            } catch (e) { contentStyleWidth = ''; contentStyleMaxWidth = ''; contentStyleTransform = ''; }

            var bodyOverflowX = '', htmlOverflowX = '';
            try { bodyOverflowX = (window.getComputedStyle(document.body).overflowX || ''); } catch (e) { bodyOverflowX = ''; }
            try { htmlOverflowX = (window.getComputedStyle(document.documentElement).overflowX || ''); } catch (e) { htmlOverflowX = ''; }

            var innerW = 0;
            var dpr = 1;
            try { innerW = window.innerWidth || 0; } catch (e) { innerW = 0; }
            try { dpr = window.devicePixelRatio || 1; } catch (e) { dpr = 1; }

            return JSON.stringify({
              hasContent: true,
              targetWidth: targetWidth,
              exportScale: exportScale,
              usesTransform: usesTransform,
              innerWidth: innerW,
              devicePixelRatio: dpr,
              contentRectWidth: contentRectW,
              contentRectHeight: contentRectH,
              contentScrollWidth: contentScrollW,
              contentOffsetWidth: contentOffsetW,
              contentComputedWidth: contentComputedWidth,
              contentComputedMaxWidth: contentComputedMaxWidth,
              contentComputedTransform: contentComputedTransform,
              contentStyleWidth: contentStyleWidth,
              contentStyleMaxWidth: contentStyleMaxWidth,
              contentStyleTransform: contentStyleTransform,
              bodyOverflowX: bodyOverflowX,
              htmlOverflowX: htmlOverflowX,
              tables: out
            });
          } catch (e) {
            return JSON.stringify({ hasContent: false, targetWidth: 0, tables: [], error: String(e) });
          }
        })();
        """

        let content = (try? await evaluateJavaScriptString(webView: webView, javaScriptString: js)) ?? ""
        try? Data(content.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        didDumpTableMetrics = true
    }


    func layoutDebugInfo(webView: WKWebView) async throws -> String {
        let js = """
        (function() {
          try {
            var c = document.getElementById('content');
            var info = {
              readyState: (document && document.readyState) ? document.readyState : 'unknown',
              hasContent: !!c,
              exportScale: window.ScopyDocument.export.state.scale || 1,
              bodyFontSize: (function() {
                try { return (window.getComputedStyle && document.body) ? window.getComputedStyle(document.body).fontSize : ''; } catch (e) { return ''; }
              })(),
              devicePixelRatio: (window && window.devicePixelRatio) ? window.devicePixelRatio : 1,
              innerHeight: (window && window.innerHeight) ? window.innerHeight : 0,
              bodyScrollHeight: (document.body && document.body.scrollHeight) ? document.body.scrollHeight : 0,
              documentScrollHeight: (document.documentElement && document.documentElement.scrollHeight) ? document.documentElement.scrollHeight : 0,
              contentScrollHeight: (c && c.scrollHeight) ? c.scrollHeight : 0,
              contentRectHeight: (c && c.getBoundingClientRect) ? Math.ceil(c.getBoundingClientRect().height || 0) : 0,
              renderFailed: !!window.ScopyDocument.state.renderFailed,
              renderErrorReason: window.ScopyDocument.state.unifiedErrorReason || ''
            };
            return JSON.stringify(info);
          } catch (e) {
            return "debugError:" + (e && e.message ? e.message : String(e));
          }
        })();
        """
        return try await evaluateJavaScriptString(webView: webView, javaScriptString: js)
    }

    nonisolated static func parseNumberFromLayoutDebugInfo(_ value: String, key: String) -> CGFloat? {
        guard let data = value.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let number = obj[key] as? NSNumber { return max(0, CGFloat(truncating: number)) }
        if let double = obj[key] as? Double { return max(0, CGFloat(double)) }
        if let int = obj[key] as? Int { return max(0, CGFloat(int)) }
        if let string = obj[key] as? String, let value = Double(string) { return max(0, CGFloat(value)) }
        return nil
    }
}
