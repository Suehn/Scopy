import assert from "node:assert/strict";
import test from "node:test";
import { freezeRichForExport, hydrateRich } from "../src/richInteractionRuntime.js";

test("currency conversion is delegated, bidirectional, bounded, and marks invalid input", () => {
  const root = element("div");
  const surface = element("section", { class: "scopy-rich", "data-scopy-rate": "2.5", "data-scopy-fraction-digits": "2" });
  const from = element("input", { "data-scopy-action": "currency-input", "data-scopy-currency-side": "from" });
  const to = element("input", { "data-scopy-action": "currency-input", "data-scopy-currency-side": "to" });
  root.append(surface.append(from, to));

  const cleanup = hydrateRich(root);
  assert.equal(root.listenerCount("input"), 1);
  hydrateRich(root);
  assert.equal(root.listenerCount("input"), 1, "hydration is idempotent");

  from.value = "4";
  root.emit("input", from);
  assert.equal(to.value, "10.00");
  assert.equal(from.getAttribute("aria-invalid"), "false");

  to.value = "5";
  root.emit("input", to);
  assert.equal(from.value, "2.00");

  from.value = "1e3";
  root.emit("input", from);
  assert.equal(from.getAttribute("aria-invalid"), "true");
  assert.equal(to.value, "5", "invalid input does not overwrite the peer");

  cleanup();
  assert.equal(root.listenerCount("input"), 0);
});

test("weather and finance controls switch only pre-rendered panels with ARIA and keyboard state", () => {
  const root = element("div");
  const weather = element("section", { class: "scopy-rich", "data-scopy-unit": "c", "data-scopy-day-index": "0" });
  const c = button("weather-unit", { "data-scopy-unit": "c" });
  const f = button("weather-unit", { "data-scopy-unit": "f" });
  const day0 = button("weather-day", { "data-scopy-index": "0" });
  const day1 = button("weather-day", { "data-scopy-index": "1" });
  const weatherPanel0 = element("div", { "data-scopy-weather-panel": "", "data-scopy-index": "0" });
  const weatherPanel1 = element("div", { "data-scopy-weather-panel": "", "data-scopy-index": "1" });
  weather.append(c, f, day0, day1, weatherPanel0, weatherPanel1);

  const finance = element("section", { class: "scopy-rich", "data-scopy-range-index": "0" });
  const range0 = button("finance-range", { "data-scopy-index": "0" });
  const range1 = button("finance-range", { "data-scopy-index": "1" });
  const financePanel0 = element("div", { "data-scopy-finance-panel": "", "data-scopy-index": "0" });
  const financePanel1 = element("div", { "data-scopy-finance-panel": "", "data-scopy-index": "1" });
  finance.append(range0, range1, financePanel0, financePanel1);
  root.append(weather, finance);

  hydrateRich(root);
  assert.equal(weatherPanel0.hidden, false);
  assert.equal(weatherPanel1.hidden, true);
  root.emit("click", f);
  assert.equal(weather.getAttribute("data-scopy-unit"), "f");
  assert.equal(f.getAttribute("aria-selected"), "true");
  assert.equal(c.getAttribute("aria-selected"), "false");

  root.emit("keydown", day0, { key: "ArrowRight" });
  assert.equal(weather.getAttribute("data-scopy-day-index"), "1");
  assert.equal(weatherPanel0.hidden, true);
  assert.equal(weatherPanel1.hidden, false);
  assert.equal(day1.focused, true);
  hydrateRich(root);
  assert.equal(weather.getAttribute("data-scopy-day-index"), "1", "re-hydration preserves live state");

  root.emit("click", range1);
  assert.equal(finance.getAttribute("data-scopy-range-index"), "1");
  assert.equal(financePanel0.hidden, true);
  assert.equal(financePanel1.hidden, false);
});

test("local-image lightbox supports navigation, Escape, and focus restoration without remote sources", () => {
  const root = element("div");
  const surface = element("section", { class: "scopy-rich" });
  const first = button("lightbox-open", { "data-scopy-index": "0", "data-scopy-lightbox-title": "One" });
  first.append(element("img", { src: "data:image/png;base64,AAAA", alt: "First" }));
  const second = button("lightbox-open", { "data-scopy-index": "1", "data-scopy-lightbox-title": "Two" });
  second.append(element("img", { src: "https://example.com/not-loaded.png", alt: "Second" }));
  const overlay = element("div", { "data-scopy-lightbox": "", hidden: "", "aria-hidden": "true" });
  const overlayImage = element("img", { "data-scopy-lightbox-image": "" });
  const title = element("span", { "data-scopy-lightbox-title": "" });
  const counter = element("span", { "data-scopy-lightbox-counter": "" });
  const close = button("lightbox-close");
  const previous = button("lightbox-prev");
  const next = button("lightbox-next");
  overlay.append(overlayImage, title, counter, close, previous, next);
  surface.append(first, second, overlay);
  root.append(surface);

  hydrateRich(root);
  root.emit("click", first);
  assert.equal(overlay.hidden, false);
  assert.equal(overlayImage.getAttribute("src"), "data:image/png;base64,AAAA");
  assert.equal(title.textContent, "One");
  assert.equal(counter.textContent, "1 / 2");
  assert.equal(close.focused, true);

  root.emit("click", next);
  assert.equal(surface.getAttribute("data-scopy-lightbox-index"), "1");
  assert.equal(overlayImage.hasAttribute("src"), false, "runtime never installs a remote image URL");
  assert.equal(title.textContent, "Two");

  root.emit("keydown", close, { key: "Escape" });
  assert.equal(overlay.hidden, true);
  assert.equal(second.focused, true);
});

test("chart probe exposes point text through a pre-rendered tooltip and hides it on leave", () => {
  const root = element("div");
  const surface = element("section", { class: "scopy-rich" });
  const probe = element("div", { "data-scopy-action": "chart-probe" });
  probe.rect = { left: 0, width: 100 };
  const point0 = element("span", { id: "point-0", "data-scopy-point-index": "0", "data-scopy-label": "Open", "data-scopy-display": "$9" });
  const point1 = element("span", { id: "point-1", "data-scopy-point-index": "1", "data-scopy-label": "Close", "data-scopy-display": "$10" });
  const tooltip = element("div", { "data-scopy-chart-tooltip": "" });
  const label = element("span", { "data-scopy-tooltip-label": "" });
  const display = element("span", { "data-scopy-tooltip-display": "" });
  tooltip.append(label, display);
  probe.append(point0, point1, tooltip);
  surface.append(probe);
  root.append(surface);

  hydrateRich(root);
  root.emit("pointermove", probe, { clientX: 90 });
  assert.equal(tooltip.hidden, false);
  assert.equal(label.textContent, "Close");
  assert.equal(display.textContent, "$10");
  assert.equal(probe.getAttribute("aria-activedescendant"), "point-1");

  root.emit("keydown", probe, { key: "Home" });
  assert.equal(label.textContent, "Open");
  root.emit("pointerleave", probe);
  assert.equal(tooltip.hidden, true);
  assert.equal(probe.hasAttribute("aria-activedescendant"), false);
});

test("source citation supporting popup clamps to both viewport edges", () => {
  const root = element("div");
  root.ownerDocument = { documentElement: { clientWidth: 800 } };
  root.offsetWidth = 800;
  root.rect = { left: 0, right: 800, width: 800 };

  const leftGroup = element("span", { class: "scopy-source-citation-group" });
  leftGroup.rect = { left: 4, right: 84, width: 80 };
  const leftLink = element("a", { class: "scopy-source-citation-link" });
  const leftPopup = element("span", { class: "scopy-source-citation-supporting" });
  leftGroup.append(leftLink, leftPopup);

  const rightGroup = element("span", { class: "scopy-source-citation-group" });
  rightGroup.rect = { left: 730, right: 790, width: 60 };
  const rightLink = element("a", { class: "scopy-source-citation-link" });
  const rightPopup = element("span", { class: "scopy-source-citation-supporting" });
  rightGroup.append(rightLink, rightPopup);
  root.append(leftGroup, rightGroup);

  hydrateRich(root);
  root.emit("pointerover", leftLink);
  assert.equal(leftPopup.style.getPropertyValue("--scopy-source-popup-max-width"), "776px");
  assert.equal(leftPopup.style.getPropertyValue("--scopy-source-popup-left"), "8px");

  root.emit("focusin", rightLink);
  assert.equal(rightPopup.style.getPropertyValue("--scopy-source-popup-left"), "-262px");
});

test("source citation popup converts viewport collision offsets into scaled local coordinates", () => {
  const root = element("div");
  root.ownerDocument = { documentElement: { clientWidth: 800 } };
  root.offsetWidth = 800;
  root.rect = { left: 0, right: 1600, width: 1600 };

  const group = element("span", { class: "scopy-source-citation-group" });
  group.rect = { left: 660, right: 780, width: 120 };
  const link = element("a", { class: "scopy-source-citation-link" });
  const popup = element("span", { class: "scopy-source-citation-supporting" });
  group.append(link, popup);
  root.append(group);

  hydrateRich(root);
  root.emit("focusin", link);

  assert.equal(popup.style.getPropertyValue("--scopy-source-popup-max-width"), "388px");
  assert.equal(popup.style.getPropertyValue("--scopy-source-popup-left"), "-260px");
});

test("export freeze disables all actions and closes transient overlays and tooltips", () => {
  const root = element("div");
  const surface = element("section", { class: "scopy-rich", "data-scopy-unit": "c" });
  const c = button("weather-unit", { "data-scopy-unit": "c" });
  const f = button("weather-unit", { "data-scopy-unit": "f" });
  const overlay = element("div", { "data-scopy-lightbox": "", "aria-hidden": "false" });
  const tooltipProbe = element("div", { "data-scopy-action": "chart-probe" });
  const tooltip = element("div", { "data-scopy-chart-tooltip": "" });
  const link = element("a", { href: "https://example.com" });
  const details = element("details", { class: "scopy-safe-details" });
  const summary = element("summary", { class: "scopy-safe-summary" });
  details.append(summary);
  tooltipProbe.append(tooltip);
  surface.append(c, f, overlay, tooltipProbe, link, details);
  root.append(surface);

  hydrateRich(root);
  overlay.hidden = false;
  tooltip.hidden = false;
  freezeRichForExport(root);

  assert.equal(root.getAttribute("data-scopy-interaction-frozen"), "true");
  assert.equal(overlay.hidden, true);
  assert.equal(tooltip.hidden, true);
  for (const control of root.querySelectorAll("[data-scopy-action]")) {
    assert.equal(control.getAttribute("aria-disabled"), "true");
    assert.equal(control.getAttribute("tabindex"), "-1");
    assert.equal(control.disabled, true);
  }
  assert.equal(link.getAttribute("aria-disabled"), "true");
  assert.equal(link.getAttribute("tabindex"), "-1");
  assert.equal(details.getAttribute("open"), "");
  assert.equal(details.open, true);
  assert.equal(summary.getAttribute("aria-disabled"), "true");
  assert.equal(summary.getAttribute("tabindex"), "-1");

  const frozenAction = root.emit("click", f);
  assert.equal(surface.getAttribute("data-scopy-unit"), "c", "frozen documents ignore delegated actions");
  assert.equal(frozenAction.defaultPrevented, true);
  assert.equal(root.emit("click", link).defaultPrevented, true, "frozen documents also cancel link defaults");

  const directlyFrozen = element("div");
  const directLink = element("a", { href: "https://example.com/direct" });
  directlyFrozen.append(directLink);
  freezeRichForExport(directlyFrozen);
  assert.equal(directlyFrozen.listenerCount("click"), 1, "direct freezing installs the cancellation delegate");
  assert.equal(directlyFrozen.emit("click", directLink).defaultPrevented, true);
});

function button(action, attributes = {}) {
  return element("button", { "data-scopy-action": action, ...attributes });
}

function element(tagName, attributes = {}) {
  return new TestElement(tagName, attributes);
}

class TestElement {
  constructor(tagName, attributes = {}) {
    this.tagName = String(tagName).toUpperCase();
    this.parentElement = null;
    this.children = [];
    this.attributes = new Map();
    this.listeners = new Map();
    this.hidden = false;
    this.disabled = false;
    this.value = "";
    this.textContent = "";
    this.focused = false;
    this.rect = { left: 0, width: 0 };
    this.style = new TestStyle();
    for (const [name, value] of Object.entries(attributes)) this.setAttribute(name, value);
  }

  get id() {
    return this.getAttribute("id") || "";
  }

  append(...nodes) {
    for (const node of nodes) {
      node.parentElement = this;
      this.children.push(node);
    }
    return this;
  }

  addEventListener(type, listener, capture = false) {
    const entries = this.listeners.get(type) || [];
    entries.push({ listener, capture });
    this.listeners.set(type, entries);
  }

  removeEventListener(type, listener, capture = false) {
    const entries = this.listeners.get(type) || [];
    this.listeners.set(type, entries.filter((entry) => entry.listener !== listener || entry.capture !== capture));
  }

  listenerCount(type) {
    return (this.listeners.get(type) || []).length;
  }

  emit(type, target, additions = {}) {
    const event = {
      type,
      target,
      key: "",
      clientX: undefined,
      shiftKey: false,
      defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; },
      ...additions
    };
    for (const { listener } of this.listeners.get(type) || []) listener(event);
    return event;
  }

  setAttribute(name, value) {
    this.attributes.set(String(name), String(value));
    if (name === "hidden") this.hidden = true;
    if (name === "disabled") this.disabled = true;
  }

  getAttribute(name) {
    return this.attributes.has(String(name)) ? this.attributes.get(String(name)) : null;
  }

  hasAttribute(name) {
    return this.attributes.has(String(name));
  }

  removeAttribute(name) {
    this.attributes.delete(String(name));
    if (name === "hidden") this.hidden = false;
    if (name === "disabled") this.disabled = false;
  }

  contains(node) {
    for (let cursor = node; cursor; cursor = cursor.parentElement) {
      if (cursor === this) return true;
    }
    return false;
  }

  matches(selector) {
    return selector.split(",").some((part) => matchesSimpleSelector(this, part.trim()));
  }

  closest(selector) {
    for (let cursor = this; cursor; cursor = cursor.parentElement) {
      if (cursor.matches(selector)) return cursor;
    }
    return null;
  }

  querySelectorAll(selector) {
    const result = [];
    const visit = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) result.push(child);
        visit(child);
      }
    };
    visit(this);
    return result;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  getBoundingClientRect() {
    return this.rect;
  }

  focus() {
    const root = rootOf(this);
    clearFocus(root);
    this.focused = true;
  }
}

class TestStyle {
  constructor() {
    this.values = new Map();
  }

  setProperty(name, value) {
    this.values.set(String(name), String(value));
  }

  getPropertyValue(name) {
    return this.values.get(String(name)) || "";
  }
}

function matchesSimpleSelector(node, selector) {
  if (!selector) return false;
  if (selector.startsWith(".")) {
    const names = String(node.getAttribute("class") || "").split(/\s+/);
    return names.includes(selector.slice(1));
  }
  if (selector.startsWith("[")) {
    const match = /^\[([^=\]]+)(?:="([^"]*)")?\]$/.exec(selector);
    if (!match) return false;
    return node.hasAttribute(match[1]) && (match[2] === undefined || node.getAttribute(match[1]) === match[2]);
  }
  return node.tagName.toLowerCase() === selector.toLowerCase();
}

function rootOf(node) {
  let root = node;
  while (root.parentElement) root = root.parentElement;
  return root;
}

function clearFocus(node) {
  node.focused = false;
  for (const child of node.children) clearFocus(child);
}
