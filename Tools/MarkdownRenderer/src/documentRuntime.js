import { render } from "./render.js";
import { freezeRichForExport, hydrateRich } from "./richInteractionRuntime.js";
import { replaceFailedSourceIcon } from "./scopySourceIcon.js";

// The Scopy Markdown document runtime, bundled into the renderer IIFE and exposed as `window.ScopyDocument`.
// `boot` renders the embedded `#scopy-render-input` ({ policy, source }) into #content, lays out pipe tables and
// task lists, hydrates rich surfaces, and publishes readiness only after the stylesheets, fonts, every image
// outcome and two paint frames reach a terminal state. Preview hosts receive render-ID-scoped metrics through
// the `scopySize` message handler; the export host drives the `export` functions on the same document.

const OVERFLOW_PROBE_SELECTOR = "pre, .katex, .footnotes";
// Both stylesheets must load before the document may report ready.
const STYLESHEET_IDS = ["scopy-katex-stylesheet", "scopy-document-stylesheet"];

const state = {
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

let input = null;
var lastH = 0;
var lastW = 0;
var lastOverflowX = false;
var lastRenderSucceeded = false;
var lastRenderErrorReason = '';
var pendingHeightReportHandle = 0;
var pendingHeightReportForce = false;
var layoutObserver = null;
function currentRenderGeneration() {
  try { return document.documentElement.getAttribute('data-scopy-render-id') || ''; } catch (e) { return ''; }
}
function isRenderReady() {
  try {
    return !!state.renderComplete && !!state.markdownRendered &&
      !!state.stylesheetReady && !!state.fontsReady && !!state.imagesReady && !!state.paintReady &&
      !state.renderFailed && state.unifiedRenderSucceeded !== false;
  } catch (e) {
    return false;
  }
}
function reportHeightNow(force) {
  try {
    if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.scopySize) { return; }
    var el = document.getElementById('content');
    if (!el) { return; }
    if (!state.renderComplete) { return; }
    layoutChatGPTTables(el);
    updateChatGPTPreviewScale(el);
    var box = document.getElementById('content-scale-shell') || el;
    var rect = box.getBoundingClientRect();
    var w = Math.ceil(rect.width || 0);
    var h = Math.ceil(rect.height || 0);
    var overflowX = false;
    try {
      var nodes = el.querySelectorAll(OVERFLOW_PROBE_SELECTOR);
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
// Offscreen probe for the prewarm path: the document's laid-out height before paint
// readiness (animation frames do not run offscreen). It seeds the popover geometry only;
// terminal readiness still arrives through scopySize after the popover is visible.
function probeLayoutHeight() {
  try {
    var el = document.getElementById('content');
    if (!el || state.renderFailed || state.unifiedRenderSucceeded !== true) { return null; }
    layoutChatGPTTables(el);
    updateChatGPTPreviewScale(el);
    var box = document.getElementById('content-scale-shell') || el;
    var rect = box.getBoundingClientRect();
    return { width: Math.ceil(rect.width || 0), height: Math.ceil(rect.height || 0), fontsReady: !!state.fontsReady };
  } catch (e) { return null; }
}
function reportHeight(force) {
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
}
function installGenerationScopedLayoutObserver() {
  var el = document.getElementById('content');
  if (!el || layoutObserver) { return; }
  var observedGeneration = currentRenderGeneration();
  if (typeof window.ResizeObserver === 'function') {
    layoutObserver = new window.ResizeObserver(function () {
      if (currentRenderGeneration() !== observedGeneration) { return; }
      reportHeight(false);
    });
    layoutObserver.observe(el);
  }
  el.addEventListener('toggle', function (event) {
    if (currentRenderGeneration() !== observedGeneration) { return; }
    var target = event && event.target;
    if (!target || String(target.tagName || '').toLowerCase() !== 'details') { return; }
    reportHeight(true);
  }, true);
  el.addEventListener('keydown', function () {
    if (currentRenderGeneration() !== observedGeneration) { return; }
    reportHeight(true);
  }, true);
  try {
    if (document.fonts && document.fonts.ready && typeof document.fonts.ready.then === 'function') {
      document.fonts.ready.then(function () {
        if (currentRenderGeneration() === observedGeneration) { reportHeight(true); }
      });
    }
  } catch (e) { }
}
function replaceFailedImage(image) {
  try {
    if (!image || !image.parentNode) { return; }
    if (replaceFailedSourceIcon(image)) { return; }
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
      if (!settled[i] && !images[i].hasAttribute('data-scopy-native-source-icon')) { finishImage(images[i], false); }
    }
  }, 1500);
  // Native icon discovery is separately bounded; other image readiness is unchanged.
  setTimeout(function () {
    for (var i = 0; i < images.length; i++) {
      if (!settled[i]) { finishImage(images[i], false); }
    }
  }, 10000);
}
function awaitStylesheetReady(completion) {
  var pending = STYLESHEET_IDS.length;
  var failure = '';
  STYLESHEET_IDS.forEach(function (id) {
    awaitOneStylesheet(document.getElementById(id), function (reason) {
      failure = failure || reason;
      pending -= 1;
      if (pending === 0) { completion(failure); }
    });
  });
}
function awaitOneStylesheet(link, completion) {
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
    // WebKit's fonts.ready also waits for layout-dependent images. Start its
    // own timeout after native icons settle, so icon discovery is not a font failure.
    awaitFontsReady(function (fontError) {
      if (fontError) { fail(fontError); return; }
      ready('fonts');
    });
  });
  awaitStylesheetReady(function (stylesheetError) {
    if (stylesheetError) {
      fail(stylesheetError);
      return;
    }
    ready('stylesheet');
  });

}
function finish(succeeded) {
  var el = document.getElementById('content');
  if (el) {
    try { el.style.opacity = '1'; } catch (e) { }
  }
  try {
    state.markdownRendered = !!succeeded;
    state.renderComplete = true;
    if (!succeeded) { state.paintReady = false; }
  } catch (e) { }
  reportHeight(true);
  setTimeout(function () {
    reportHeight(true);
  }, 120);
}
function failUnifiedRender(reason) {
  var el = document.getElementById('content');
  if (!el) { return; }
  try {
    state.unifiedErrorReason = reason || 'unified render failed';
    state.renderFailed = true;
    state.unifiedRenderSucceeded = false;
  } catch (e) { }
  el.innerHTML = '<p class="scopy-render-error">Markdown renderer failed to load.</p>';
  finish(false);
}
function renderUnified() {
  var el = document.getElementById('content');
  if (!el) { return; }
  try {
    state.renderComplete = false;
    state.markdownRendered = false;
    state.renderFailed = false;
    state.unifiedRenderSucceeded = false;
    state.unifiedErrorReason = '';
    state.stylesheetReady = false;
    state.fontsReady = false;
    state.imagesReady = false;
    state.paintReady = false;
    state.layoutEpoch = 0;
    state.hydrationWarning = '';
    state.renderPass = (state.renderPass || 0) + 1;
  } catch (e) { }
  if (!input || typeof input.source !== 'string') {
    failUnifiedRender('render input unreadable');
    return;
  }
  var result = null;
  try {
    result = render(input.source, input.policy || {});
  } catch (e) {
    failUnifiedRender('unified render exception');
    return;
  }
  if (!result || !result.html) {
    failUnifiedRender('unified returned empty html');
    return;
  }
  el.innerHTML = result.html;
  state.unifiedRenderSucceeded = true;
  try {
    applyTaskLists(el);
  } catch (e) {
    state.hydrationWarning = 'task-list hydration failed';
  }
  try {
    var exportMode = !!(document.documentElement && document.documentElement.classList && document.documentElement.classList.contains('scopy-export-mode'));
    hydrateRich(el, { exportMode: exportMode });
  } catch (e) {
    var priorWarning = state.hydrationWarning || '';
    state.hydrationWarning = priorWarning ? priorWarning + '; rich hydration failed' : 'rich hydration failed';
  }
  layoutChatGPTTables(el);
  awaitTerminalReadiness(el);
}

// MARK: - Pipe-table model

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
        try { text = String(cells[c].textContent || '').replace(/\s+/g, ' ').trim(); } catch (e) { text = ''; }
        lengths[c] = Math.max(lengths[c] || 0, text.length || 0);
      }
    }
  } catch (e) { }
  return lengths;
}
export function tableColumnSize(length) {
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
        var size = c < lengths.length ? tableColumnSize(lengths[c] || 0) : 'sm';
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

// MARK: - Task lists

function firstMeaningfulTextNode(node) {
  if (!node) { return null; }
  var child = node.firstChild;
  while (child) {
    if (child.nodeType === Node.TEXT_NODE && /\S/.test(child.nodeValue || '')) {
      return child;
    }
    if (child.nodeType === Node.ELEMENT_NODE) {
      var tag = child.tagName;
      if (tag !== 'UL' && tag !== 'OL') {
        var nested = firstMeaningfulTextNode(child);
        if (nested) { return nested; }
      }
    }
    child = child.nextSibling;
  }
  return null;
}

function markerTargetForListItem(item) {
  if (!item) { return null; }
  var child = item.firstChild;
  while (child) {
    if (child.nodeType === Node.TEXT_NODE && /\S/.test(child.nodeValue || '')) {
      return { container: item, node: child };
    }
    if (child.nodeType === Node.ELEMENT_NODE) {
      var tag = child.tagName;
      if (tag === 'UL' || tag === 'OL') { break; }
      var nested = firstMeaningfulTextNode(child);
      if (nested) {
        return { container: child, node: nested };
      }
    }
    child = child.nextSibling;
  }
  return null;
}

function firstTaskInput(node) {
  if (!node) { return null; }
  var child = node.firstChild;
  while (child) {
    if (child.nodeType === Node.ELEMENT_NODE) {
      var tag = child.tagName;
      if (tag === 'UL' || tag === 'OL') { break; }
      if (tag === 'INPUT' && (child.getAttribute('type') || '').toLowerCase() === 'checkbox') {
        return child;
      }
      var nested = firstTaskInput(child);
      if (nested) { return nested; }
    }
    child = child.nextSibling;
  }
  return null;
}

function createTaskMarker(checked) {
  var marker = document.createElement('span');
  marker.className = 'task-list-item-marker';
  marker.setAttribute('role', 'checkbox');
  marker.setAttribute('aria-checked', checked ? 'true' : 'false');
  marker.setAttribute('data-checked', checked ? 'true' : 'false');
  return marker;
}

function hideNativeTaskInput(input) {
  input.setAttribute('hidden', 'hidden');
  input.setAttribute('aria-hidden', 'true');
  input.setAttribute('tabindex', '-1');
}

function markTaskListContainer(item) {
  item.classList.add('task-list-item');
  var list = item.parentElement;
  if (list && (list.tagName === 'UL' || list.tagName === 'OL')) {
    list.classList.add('task-list-container');
  }
}

function normalizeExistingTaskInput(item) {
  var existingMarker = item.querySelector('.task-list-item-marker');
  if (existingMarker) {
    markTaskListContainer(item);
    return true;
  }

  var nativeInput = firstTaskInput(item);
  if (!nativeInput) { return false; }

  var checked = nativeInput.checked || nativeInput.hasAttribute('checked');
  hideNativeTaskInput(nativeInput);
  var marker = createTaskMarker(checked);

  var anchor = nativeInput;
  if (nativeInput.parentElement && nativeInput.parentElement !== item && nativeInput.parentElement.parentElement === item) {
    anchor = nativeInput.parentElement;
  }
  item.insertBefore(marker, anchor);
  markTaskListContainer(item);
  return true;
}

function applyTaskListItem(item) {
  if (!item) { return; }
  if (normalizeExistingTaskInput(item)) { return; }

  var target = markerTargetForListItem(item);
  if (!target || !target.node) { return; }
  var value = target.node.nodeValue || '';
  var match = value.match(/^(\s*)\[([ xX])\](\s+|$)/);
  if (!match) { return; }

  target.node.nodeValue = (match[1] || '') + value.slice(match[0].length);

  var marker = createTaskMarker(/[xX]/.test(match[2]));

  if (target.container === item) {
    item.insertBefore(marker, target.node);
  } else {
    item.insertBefore(marker, target.container);
  }
  markTaskListContainer(item);

  var nativeInputs = item.querySelectorAll('input[type="checkbox"]');
  for (var i = 0; i < nativeInputs.length; i++) {
    hideNativeTaskInput(nativeInputs[i]);
  }
}

function applyTaskLists(root) {
  if (!root) { return; }
  var items = root.querySelectorAll('li');
  for (var i = 0; i < items.length; i++) {
    applyTaskListItem(items[i]);
  }
}

// MARK: - Export

// Set by applyExportScale; the layout watcher and wide-content measurement divide it back out.
const exportState = { scale: 1, usesTransform: false };
let layoutWatcher = null;

function prepareExport() {
  try {
    try { document.documentElement.classList.add('scopy-export-mode'); } catch (e) { }
    var content = document.getElementById('content');
    if (content) {
      try { content.style.opacity = '1'; } catch (e) { }
      try { content.style.transition = 'none'; } catch (e) { }
      try { freezeRichForExport(content); } catch (e) { }
      try { syncChatGPTZoomShell(content); } catch (e) { }
    }
  } catch (e) { }
  return true;
}

// Fits wide tables, display/inline math and code to the export width after preview-equivalent layout;
// it never changes parsing, typography or the content width.
function adjustWideContentForExport(widthPoints) {
  var w = widthPoints;
  function computeTargetWidthPoints(content) {
    var padL = 0, padR = 0;
    try {
      var cs = window.getComputedStyle(content);
      padL = parseFloat(cs.paddingLeft) || 0;
      padR = parseFloat(cs.paddingRight) || 0;
    } catch (e) { padL = 0; padR = 0; }
    var layoutW = 0;
    try { layoutW = Math.ceil(content.clientWidth || content.offsetWidth || 0); } catch (e) { layoutW = 0; }
    if (!layoutW || !isFinite(layoutW) || layoutW <= 0) {
      try {
        var raw = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-render-width');
        layoutW = Math.ceil(parseFloat(raw) || 0);
      } catch (e) { layoutW = 0; }
    }
    if (!layoutW || !isFinite(layoutW) || layoutW <= 0) { layoutW = w; }

    // Table export starts from the same unscaled content box as preview. A later global transform may shrink
    // the entire rendered surface for PNG area limits, but it must not change text/table layout widths.
    return Math.max(1, Math.floor(layoutW - padL - padR));
  }
  function measureBlockWidth(node) {
    if (!node) { return 0; }
    try { void node.offsetHeight; } catch (e) { }
    var rectW = 0, scrollW = 0, offsetW = 0, clientW = 0;
    try {
      rectW = Math.ceil((node.getBoundingClientRect().width || 0));
      var browserZoom = 1;
      try {
        var rawZoom = window.getComputedStyle(document.documentElement).getPropertyValue('--scopy-chatgpt-browser-zoom');
        browserZoom = parseFloat(rawZoom) || 1;
      } catch (e) { browserZoom = 1; }
      if (browserZoom && isFinite(browserZoom) && browserZoom > 0 && browserZoom !== 1) {
        rectW = Math.ceil(rectW / browserZoom);
      }
    } catch (e) { rectW = 0; }
    try { scrollW = Math.ceil((node.scrollWidth || 0)); } catch (e) { scrollW = 0; }
    try { offsetW = Math.ceil((node.offsetWidth || 0)); } catch (e) { offsetW = 0; }
    try { clientW = Math.ceil((node.clientWidth || 0)); } catch (e) { clientW = 0; }
    return Math.max(rectW, scrollW, offsetW, clientW);
  }

  function adaptWideCodeBlocks(content, targetWidth) {
    if (!content || !content.querySelectorAll) { return; }
    var blocks = content.querySelectorAll('pre');
    for (var i = 0; i < (blocks.length || 0); i++) {
      var pre = blocks[i];
      if (!pre || !pre.classList) { continue; }
      try { pre.classList.remove('scopy-export-wrap-code'); } catch (e) { }
      var rawWidth = measureBlockWidth(pre);
      if (rawWidth > targetWidth + 1) {
        try { pre.classList.add('scopy-export-wrap-code'); } catch (e) { }
      }
    }
  }

  function scaleWideMath(content, targetWidth) {
    if (!content || !content.querySelectorAll) { return; }
    var displays = content.querySelectorAll('.katex-display');
    for (var i = 0; i < (displays.length || 0); i++) {
      var display = displays[i];
      var math = display && display.querySelector ? display.querySelector('.katex') : null;
      if (!display || !math || !math.style) { continue; }
      var available = 0;
      try { available = Math.floor(display.clientWidth || 0); } catch (e) { available = 0; }
      if (!available || available <= 0) { available = targetWidth; }
      available = Math.min(targetWidth, available);
      var rawWidth = measureBlockWidth(math);
      if (!rawWidth || rawWidth <= available + 1) { continue; }
      var scale = available / rawWidth;
      if (!scale || !isFinite(scale) || scale <= 0 || scale >= 0.999) { continue; }
      var rawHeight = 0;
      try { rawHeight = Math.ceil(math.offsetHeight || math.scrollHeight || math.getBoundingClientRect().height || 0); } catch (e) { rawHeight = 0; }
      math.style.transform = 'scale(' + scale + ')';
      math.style.transformOrigin = 'top center';
      display.style.overflow = 'visible';
      display.style.maxWidth = '100%';
      if (rawHeight > 0) { display.style.height = Math.ceil(rawHeight * scale + 1) + 'px'; }
      if (display.dataset) { display.dataset.scopyExportMathScaled = 'true'; }
    }

    var inlineHosts = content.querySelectorAll('.scopy-math-inline-host');
    for (var j = 0; j < (inlineHosts.length || 0); j++) {
      var host = inlineHosts[j];
      var inlineMath = host && host.querySelector ? host.querySelector('.katex') : null;
      if (!host || !inlineMath || !inlineMath.style || !host.style) { continue; }
      var inlineAvailable = 0;
      try { inlineAvailable = Math.floor(host.clientWidth || 0); } catch (e) { inlineAvailable = 0; }
      if (!inlineAvailable || inlineAvailable <= 0) { inlineAvailable = targetWidth; }
      inlineAvailable = Math.min(targetWidth, inlineAvailable);
      var inlineRawWidth = measureBlockWidth(inlineMath);
      if (!inlineRawWidth || inlineRawWidth <= inlineAvailable + 1) { continue; }
      var inlineScale = inlineAvailable / inlineRawWidth;
      if (!inlineScale || !isFinite(inlineScale) || inlineScale <= 0 || inlineScale >= 0.999) { continue; }
      var inlineRawHeight = 0;
      try { inlineRawHeight = Math.ceil(inlineMath.offsetHeight || inlineMath.scrollHeight || inlineMath.getBoundingClientRect().height || 0); } catch (e) { inlineRawHeight = 0; }
      inlineMath.style.transform = 'scale(' + inlineScale + ')';
      inlineMath.style.transformOrigin = 'left center';
      host.style.overflow = 'visible';
      host.style.maxWidth = '100%';
      host.style.width = Math.ceil(inlineRawWidth * inlineScale + 1) + 'px';
      if (inlineRawHeight > 0) { host.style.height = Math.ceil(inlineRawHeight * inlineScale + 1) + 'px'; }
      if (host.dataset) { host.dataset.scopyExportMathScaled = 'true'; }
    }
  }

  var content = document.getElementById('content');
  if (!content) { return false; }
  var targetWidth = computeTargetWidthPoints(content);
  try { syncChatGPTZoomShell(content); } catch (e) { }
  scaleChatGPTTablesForExport(content, targetWidth);
  scaleWideMath(content, targetWidth);
  adaptWideCodeBlocks(content, targetWidth);
  try { syncChatGPTZoomShell(content); } catch (e) { }
  return true;
}

// Scales the whole rendered surface for PNG area limits. The fixed-width layout shell keeps its unscaled width,
// so paragraph wrapping and table column measurement stay aligned with preview.
function applyExportScale(scale) {
  try {
    // Reset any prior scaling so we can re-apply deterministically.
    try { document.documentElement.style.zoom = ''; } catch (e) { }
    try { document.body && (document.body.style.zoom = ''); } catch (e) { }

    var nextScale = Number(scale);
    if (!nextScale || !isFinite(nextScale) || nextScale <= 0) { nextScale = 1; }
    exportState.scale = nextScale;
    exportState.usesTransform = true;

    var body = document.body;
    if (!body) { return false; }
    var content = document.getElementById('content');
    if (!content) { return false; }
    var browserZoom = readCSSPixelVariable(document.documentElement, '--scopy-chatgpt-browser-zoom', 1);

    try {
      content.style.transformOrigin = 'top left';
      content.style.transform = 'scale(' + (browserZoom * nextScale) + ')';

      // Prefer an explicit pixel width for the unscaled layout. Very large percentage widths can be clamped or
      // handled inconsistently by WebKit's PDF pipeline, resulting in a blank right margin after scaling.
      var widthPx = Math.max(1, Math.ceil(content.clientWidth || content.offsetWidth || 0));
      content.style.setProperty('width', widthPx + 'px', 'important');
      content.style.setProperty('max-width', widthPx + 'px', 'important');
      content.style.display = 'block';
      try {
        var shell = document.getElementById('content-scale-shell');
        var rawHeight = Math.ceil(content.scrollHeight || content.offsetHeight || 0);
        if (shell && rawHeight && isFinite(rawHeight) && rawHeight > 0) {
          shell.style.height = Math.ceil(rawHeight * browserZoom * nextScale) + 'px';
        }
      } catch (e) { }
    } catch (e) { return false; }

    // Ensure font-size reset so we don't double-scale text.
    try { body.style.fontSize = ''; } catch (e) { }
    return true;
  } catch (e) {
    return false;
  }
}

// An animation-frame watcher: it measures the export height every frame and counts how many consecutive frames it
// has been unchanged, so the host can wait for layout to settle instead of sleeping. The first call installs it;
// every call returns the current sample as JSON.
function watchLayout() {
  if (!layoutWatcher) {
    var w = { frames: 0, stableFrames: 0, height: 0, live: 0, lastHeight: -1, lastLive: -1, fonts: 'n/a',
              renderReady: false, renderFailed: false, renderErrorReason: '' };
    layoutWatcher = w;
    var measureHeight = function () {
      var c = document.getElementById('content');
      if (!c) { return 0; }
      var rectH = 0;
      try {
        var shell = document.getElementById('content-scale-shell') || c;
        rectH = Math.ceil(shell.getBoundingClientRect().height || 0);
      } catch (e) { rectH = 0; }
      var sh = 0;
      try { sh = Math.ceil(c.scrollHeight || 0); } catch (e) { sh = 0; }
      // Prefer #content measurements so short content is not padded to the viewport height.
      return Math.ceil((exportState.usesTransform && rectH > 0) ? rectH : Math.max(rectH || 0, sh || 0));
    };
    var measureLive = function () {
      var c = document.getElementById('content');
      if (!c) { return 0; }
      var rectH = 0;
      try { rectH = Math.ceil(c.getBoundingClientRect().height || 0); } catch (e) { rectH = 0; }
      if (exportState.scale > 0 && Math.abs(exportState.scale - 1) > 0.001 && rectH > 0) { return rectH; }
      var sh = 0;
      try { sh = c.scrollHeight || 0; } catch (e) { sh = 0; }
      return Math.max(sh, rectH);
    };
    var tick = function () {
      w.frames += 1;
      var h = 0; try { h = measureHeight(); } catch (e) { h = 0; }
      var live = 0; try { live = measureLive(); } catch (e) { live = 0; }
      var ready = isRenderReady();
      w.renderFailed = !!state.renderFailed;
      w.renderErrorReason = state.unifiedErrorReason || '';
      try { w.fonts = (document.fonts && document.fonts.status) ? document.fonts.status : 'n/a'; } catch (e) { w.fonts = 'n/a'; }
      if (ready && h > 0 && w.lastHeight >= 0 && Math.abs(h - w.lastHeight) < 1 && Math.abs(live - w.lastLive) < 1) {
        w.stableFrames += 1;
      } else {
        w.stableFrames = 0;
      }
      w.lastHeight = h; w.lastLive = live; w.height = h; w.live = live; w.renderReady = ready;
      window.requestAnimationFrame(tick);
    };
    window.requestAnimationFrame(tick);
  }
  var s = layoutWatcher;
  return JSON.stringify({ frames: s.frames, stableFrames: s.stableFrames, height: s.height, live: s.live,
    fonts: s.fonts, renderReady: s.renderReady, renderFailed: s.renderFailed, renderErrorReason: s.renderErrorReason });
}

// MARK: - Boot

let booted = false;

function boot() {
  var node = document.getElementById('scopy-render-input');
  if (booted || !node) { return; }
  booted = true;
  try { input = JSON.parse(node.textContent || ''); } catch (e) { input = null; }
  installGenerationScopedLayoutObserver();
  renderUnified();
  window.addEventListener('load', function () {
    reportHeight(true);
    setTimeout(function () { reportHeight(true); }, 120);
  });
  window.addEventListener('resize', function () {
    reportHeight(true);
    setTimeout(function () { reportHeight(true); }, 60);
  });
}

export const scopyDocument = Object.freeze({
  boot,
  isRenderReady,
  probeLayoutHeight,
  reportHeight,
  state,
  export: Object.freeze({
    prepare: prepareExport,
    adjustWideContent: adjustWideContentForExport,
    applyScale: applyExportScale,
    watchLayout,
    state: exportState
  })
});
