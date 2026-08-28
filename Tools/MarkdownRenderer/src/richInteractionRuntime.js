const hydratedRoots = new WeakMap();
const surfaceState = new WeakMap();

const ACTION_SELECTOR = "[data-scopy-action]";
const SURFACE_SELECTOR = ".scopy-rich, [data-scopy-interactive]";
const CURRENCY_INPUT_SELECTOR = '[data-scopy-action="currency-input"]';
const WEATHER_UNIT_SELECTOR = '[data-scopy-action="weather-unit"]';
const WEATHER_DAY_SELECTOR = '[data-scopy-action="weather-day"]';
const WEATHER_PANEL_SELECTOR = "[data-scopy-weather-panel]";
const FINANCE_RANGE_SELECTOR = '[data-scopy-action="finance-range"]';
const FINANCE_PANEL_SELECTOR = "[data-scopy-finance-panel]";
const LIGHTBOX_OPEN_SELECTOR = '[data-scopy-action="lightbox-open"]';
const LIGHTBOX_SELECTOR = "[data-scopy-lightbox]";
const CHART_PROBE_SELECTOR = '[data-scopy-action="chart-probe"]';
const CHART_POINT_SELECTOR = "[data-scopy-point-index], [data-scopy-chart-point]";
const CHART_TOOLTIP_SELECTOR = "[data-scopy-chart-tooltip]";
const SOURCE_CITATION_GROUP_SELECTOR = ".scopy-source-citation-group";
const SOURCE_CITATION_SUPPORTING_SELECTOR = ".scopy-source-citation-supporting";
const EXPORT_FOCUSABLE_SELECTOR = "a, [data-scopy-action]";

const DECIMAL_PATTERN = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/;
const MAX_DECIMAL_LENGTH = 128;
const MAX_FRACTION_DIGITS = 12;

export function hydrateRich(root, { exportMode = false } = {}) {
  if (!isEventRoot(root)) return () => {};

  let state = hydratedRoots.get(root);
  if (!state) {
    state = makeRootState(root);
    hydratedRoots.set(root, state);
    installDelegates(root, state);
  }

  initializeSurfaces(root);
  if (exportMode) {
    freezeRichForExport(root);
  }

  return function cleanupRichInteractions() {
    const current = hydratedRoots.get(root);
    if (current !== state) return;
    removeDelegates(root, state);
    hydratedRoots.delete(root);
  };
}

export function freezeRichForExport(root) {
  if (!root || typeof root.querySelectorAll !== "function") return;

  if (!hydratedRoots.has(root)) hydrateRich(root);
  const state = hydratedRoots.get(root);
  if (state) state.exportMode = true;

  setAttribute(root, "data-scopy-interaction-frozen", "true");
  for (const surface of surfacesWithin(root)) {
    closeLightbox(surface, { restoreFocus: false });
    hideChartTooltips(surface);
  }

  for (const control of queryAll(root, EXPORT_FOCUSABLE_SELECTOR)) {
    setAttribute(control, "aria-disabled", "true");
    setAttribute(control, "tabindex", "-1");
    if (getAttribute(control, "data-scopy-action") != null) {
      if ("disabled" in control) control.disabled = true;
      setAttribute(control, "disabled", "");
    }
  }
}

function makeRootState(root) {
  return {
    root,
    exportMode: false,
    listeners: {
      click: (event) => handleClick(root, event),
      input: (event) => handleInput(root, event),
      keydown: (event) => handleKeyDown(root, event),
      pointerover: (event) => positionSourceCitationPopup(root, event),
      focusin: (event) => positionSourceCitationPopup(root, event),
      pointermove: (event) => handlePointerMove(root, event),
      pointerleave: (event) => handlePointerLeave(root, event)
    }
  };
}

function installDelegates(root, state) {
  root.addEventListener("click", state.listeners.click);
  root.addEventListener("input", state.listeners.input);
  root.addEventListener("keydown", state.listeners.keydown);
  root.addEventListener("pointerover", state.listeners.pointerover);
  root.addEventListener("focusin", state.listeners.focusin);
  root.addEventListener("pointermove", state.listeners.pointermove);
  root.addEventListener("pointerleave", state.listeners.pointerleave, true);
}

function removeDelegates(root, state) {
  root.removeEventListener("click", state.listeners.click);
  root.removeEventListener("input", state.listeners.input);
  root.removeEventListener("keydown", state.listeners.keydown);
  root.removeEventListener("pointerover", state.listeners.pointerover);
  root.removeEventListener("focusin", state.listeners.focusin);
  root.removeEventListener("pointermove", state.listeners.pointermove);
  root.removeEventListener("pointerleave", state.listeners.pointerleave, true);
}

function initializeSurfaces(root) {
  for (const surface of surfacesWithin(root)) {
    if (surfaceState.has(surface)) continue;
    surfaceState.set(surface, { lightboxOpener: null, chartPointIndex: new WeakMap() });
    initializeWeather(surface);
    initializeFinance(surface);
    initializeLightbox(surface);
    hideChartTooltips(surface);
  }
}

function initializeWeather(surface) {
  const unitButtons = queryAll(surface, WEATHER_UNIT_SELECTOR);
  if (unitButtons.length > 0) {
    const requested = getAttribute(surface, "data-scopy-unit");
    const selected = unitButtons.find((button) => getAttribute(button, "data-scopy-unit") === requested) || unitButtons[0];
    selectWeatherUnit(surface, selected);
  }

  const dayButtons = queryAll(surface, WEATHER_DAY_SELECTOR);
  const panels = queryAll(surface, WEATHER_PANEL_SELECTOR);
  if (dayButtons.length > 0 || panels.length > 0) {
    const requested = boundedIndex(getAttribute(surface, "data-scopy-day-index"), Math.max(dayButtons.length, panels.length));
    selectIndexedState(surface, {
      index: requested == null ? 0 : requested,
      rootAttribute: "data-scopy-day-index",
      buttons: dayButtons,
      panels
    });
  }
}

function initializeFinance(surface) {
  const buttons = queryAll(surface, FINANCE_RANGE_SELECTOR);
  const panels = queryAll(surface, FINANCE_PANEL_SELECTOR);
  if (buttons.length === 0 && panels.length === 0) return;
  const requested = boundedIndex(getAttribute(surface, "data-scopy-range-index"), Math.max(buttons.length, panels.length));
  selectIndexedState(surface, {
    index: requested == null ? 0 : requested,
    rootAttribute: "data-scopy-range-index",
    buttons,
    panels
  });
}

function initializeLightbox(surface) {
  const overlay = queryOne(surface, LIGHTBOX_SELECTOR);
  if (!overlay) return;
  setHidden(overlay, true);
  setAttribute(overlay, "aria-hidden", "true");
  removeAttribute(surface, "data-scopy-lightbox-index");
}

function handleClick(root, event) {
  if (isFrozen(root)) {
    preventDefault(event);
    return;
  }
  const actionNode = closestWithin(event?.target, ACTION_SELECTOR, root);
  if (!actionNode) return;
  const surface = closestWithin(actionNode, SURFACE_SELECTOR, root);
  if (!surface) return;

  const action = getAttribute(actionNode, "data-scopy-action");
  switch (action) {
    case "weather-unit":
      selectWeatherUnit(surface, actionNode);
      break;
    case "weather-day":
      activateIndexedControl(surface, actionNode, WEATHER_DAY_SELECTOR, WEATHER_PANEL_SELECTOR, "data-scopy-day-index");
      break;
    case "finance-range":
      activateIndexedControl(surface, actionNode, FINANCE_RANGE_SELECTOR, FINANCE_PANEL_SELECTOR, "data-scopy-range-index");
      break;
    case "lightbox-open":
      openLightbox(surface, actionNode);
      break;
    case "lightbox-close":
      closeLightbox(surface, { restoreFocus: true });
      break;
    case "lightbox-prev":
      stepLightbox(surface, -1);
      break;
    case "lightbox-next":
      stepLightbox(surface, 1);
      break;
    default:
      return;
  }
  reportHeight();
  preventDefault(event);
}

function handleInput(root, event) {
  if (isFrozen(root)) return;
  const input = closestWithin(event?.target, CURRENCY_INPUT_SELECTOR, root);
  if (!input) return;
  const surface = closestWithin(input, SURFACE_SELECTOR, root);
  if (!surface) return;
  updateCurrency(surface, input);
  reportHeight();
}

function updateCurrency(surface, input) {
  const side = getAttribute(input, "data-scopy-currency-side");
  if (side !== "from" && side !== "to") return;

  const inputs = queryAll(surface, CURRENCY_INPUT_SELECTOR);
  const peer = inputs.find((candidate) => getAttribute(candidate, "data-scopy-currency-side") === (side === "from" ? "to" : "from"));
  if (!peer) return;

  const amount = parseDecimal(input.value);
  const rate = parseDecimal(getAttribute(surface, "data-scopy-rate"));
  const fractionDigits = parseFractionDigits(getAttribute(surface, "data-scopy-fraction-digits"));
  if (amount == null || rate == null || rate <= 0 || (side === "to" && rate === 0)) {
    setAttribute(input, "aria-invalid", "true");
    return;
  }

  const converted = side === "from" ? amount * rate : amount / rate;
  if (!Number.isFinite(converted)) {
    setAttribute(input, "aria-invalid", "true");
    return;
  }

  setAttribute(input, "aria-invalid", "false");
  setAttribute(peer, "aria-invalid", "false");
  peer.value = formatDecimal(converted, fractionDigits);
}

function selectWeatherUnit(surface, selected) {
  const unit = getAttribute(selected, "data-scopy-unit");
  if (!unit) return;
  setAttribute(surface, "data-scopy-unit", unit);
  for (const button of queryAll(surface, WEATHER_UNIT_SELECTOR)) {
    const active = getAttribute(button, "data-scopy-unit") === unit;
    setAttribute(button, "aria-pressed", active ? "true" : "false");
    setAttribute(button, "aria-selected", active ? "true" : "false");
    setAttribute(button, "tabindex", active ? "0" : "-1");
  }
  for (const value of queryAll(surface, "[data-scopy-unit-value]")) {
    const active = getAttribute(value, "data-scopy-unit-value") === unit;
    setHidden(value, !active);
    setAttribute(value, "aria-hidden", active ? "false" : "true");
  }
}

function activateIndexedControl(surface, button, buttonSelector, panelSelector, rootAttribute) {
  const buttons = queryAll(surface, buttonSelector);
  const panels = queryAll(surface, panelSelector);
  const fallbackIndex = buttons.indexOf(button);
  const requested = boundedIndex(getAttribute(button, "data-scopy-index"), Math.max(buttons.length, panels.length));
  const index = requested == null ? fallbackIndex : requested;
  if (index < 0) return;
  selectIndexedState(surface, { index, rootAttribute, buttons, panels });
}

function selectIndexedState(surface, { index, rootAttribute, buttons, panels }) {
  setAttribute(surface, rootAttribute, String(index));
  for (let position = 0; position < buttons.length; position += 1) {
    const buttonIndex = indexedNodeValue(buttons[position], position);
    const active = buttonIndex === index;
    setAttribute(buttons[position], "aria-selected", active ? "true" : "false");
    setAttribute(buttons[position], "aria-pressed", active ? "true" : "false");
    setAttribute(buttons[position], "aria-checked", active ? "true" : "false");
    setAttribute(buttons[position], "tabindex", active ? "0" : "-1");
  }
  for (let position = 0; position < panels.length; position += 1) {
    const panelIndex = indexedNodeValue(panels[position], position);
    const active = panelIndex === index;
    setHidden(panels[position], !active);
    setAttribute(panels[position], "aria-hidden", active ? "false" : "true");
  }
}

function handleKeyDown(root, event) {
  if (isFrozen(root)) return;
  const target = event?.target;
  const actionNode = closestWithin(target, ACTION_SELECTOR, root);
  const surface = actionNode ? closestWithin(actionNode, SURFACE_SELECTOR, root) : closestWithin(target, SURFACE_SELECTOR, root);
  if (!surface) return;

  const key = String(event?.key || "");
  if (isLightboxOpen(surface)) {
    if (key === "Escape") {
      closeLightbox(surface, { restoreFocus: true });
      preventDefault(event);
      return;
    }
    if (key === "ArrowLeft" || key === "ArrowRight") {
      stepLightbox(surface, key === "ArrowLeft" ? -1 : 1);
      preventDefault(event);
      return;
    }
    if (key === "Tab") {
      trapLightboxFocus(surface, event);
      return;
    }
  }

  const action = actionNode ? getAttribute(actionNode, "data-scopy-action") : "";
  if (action === "weather-unit") {
    moveAmongControls(surface, actionNode, WEATHER_UNIT_SELECTOR, key, (button) => selectWeatherUnit(surface, button), event);
  } else if (action === "weather-day") {
    moveAmongControls(surface, actionNode, WEATHER_DAY_SELECTOR, key, (button) => activateIndexedControl(surface, button, WEATHER_DAY_SELECTOR, WEATHER_PANEL_SELECTOR, "data-scopy-day-index"), event);
  } else if (action === "finance-range") {
    moveAmongControls(surface, actionNode, FINANCE_RANGE_SELECTOR, key, (button) => activateIndexedControl(surface, button, FINANCE_RANGE_SELECTOR, FINANCE_PANEL_SELECTOR, "data-scopy-range-index"), event);
  } else if (action === "chart-probe") {
    moveChartPoint(actionNode, key, event, surface);
  }
}

function moveAmongControls(surface, current, selector, key, activate, event) {
  if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(key)) return;
  const controls = queryAll(surface, selector).filter((node) => !node.disabled && getAttribute(node, "aria-disabled") !== "true");
  if (controls.length === 0) return;
  let index = Math.max(0, controls.indexOf(current));
  if (key === "Home") index = 0;
  else if (key === "End") index = controls.length - 1;
  else if (key === "ArrowLeft" || key === "ArrowUp") index = (index - 1 + controls.length) % controls.length;
  else index = (index + 1) % controls.length;
  activate(controls[index]);
  focus(controls[index]);
  preventDefault(event);
}

function openLightbox(surface, opener) {
  const overlay = queryOne(surface, LIGHTBOX_SELECTOR);
  if (!overlay) return;
  const openers = queryAll(surface, LIGHTBOX_OPEN_SELECTOR);
  const position = openers.indexOf(opener);
  const requested = boundedIndex(getAttribute(opener, "data-scopy-index"), openers.length);
  const index = requested == null ? position : requested;
  if (index < 0) return;

  const image = queryOne(opener, "img");
  const source = image ? getAttribute(image, "src") : getAttribute(opener, "data-scopy-lightbox-src");
  const overlayImage = queryOne(overlay, "[data-scopy-lightbox-image]");
  if (overlayImage && isOfflineImageSource(source)) {
    setAttribute(overlayImage, "src", source);
    setAttribute(overlayImage, "alt", image ? getAttribute(image, "alt") || "" : "");
  } else if (overlayImage) {
    removeAttribute(overlayImage, "src");
  }

  const title = getAttribute(opener, "data-scopy-lightbox-title") || (image ? getAttribute(image, "alt") : "") || "";
  const sourceLabel = getAttribute(opener, "data-scopy-lightbox-source") || "";
  setText(queryOne(overlay, "[data-scopy-lightbox-title]"), title);
  setText(queryOne(overlay, "[data-scopy-lightbox-source]"), sourceLabel);
  setText(queryOne(overlay, "[data-scopy-lightbox-counter]"), `${index + 1} / ${openers.length}`);
  setAttribute(surface, "data-scopy-lightbox-index", String(index));
  setHidden(overlay, false);
  setAttribute(overlay, "aria-hidden", "false");

  const state = surfaceState.get(surface) || { lightboxOpener: null, chartPointIndex: new WeakMap() };
  state.lightboxOpener = opener;
  surfaceState.set(surface, state);
  focus(queryOne(overlay, '[data-scopy-action="lightbox-close"]') || overlay);
}

function closeLightbox(surface, { restoreFocus }) {
  const overlay = queryOne(surface, LIGHTBOX_SELECTOR);
  if (!overlay) return;
  setHidden(overlay, true);
  setAttribute(overlay, "aria-hidden", "true");
  const overlayImage = queryOne(overlay, "[data-scopy-lightbox-image]");
  if (overlayImage) removeAttribute(overlayImage, "src");
  removeAttribute(surface, "data-scopy-lightbox-index");
  const state = surfaceState.get(surface);
  if (restoreFocus && state?.lightboxOpener) focus(state.lightboxOpener);
  if (state) state.lightboxOpener = null;
}

function stepLightbox(surface, delta) {
  const openers = queryAll(surface, LIGHTBOX_OPEN_SELECTOR);
  if (openers.length === 0) return;
  const current = boundedIndex(getAttribute(surface, "data-scopy-lightbox-index"), openers.length) ?? 0;
  const next = (current + delta + openers.length) % openers.length;
  openLightbox(surface, openers[next]);
}

function trapLightboxFocus(surface, event) {
  const overlay = queryOne(surface, LIGHTBOX_SELECTOR);
  if (!overlay) return;
  const controls = queryAll(overlay, ACTION_SELECTOR).filter((node) => !node.disabled && getAttribute(node, "aria-disabled") !== "true");
  if (controls.length === 0) {
    preventDefault(event);
    focus(overlay);
    return;
  }
  const current = controls.indexOf(event.target);
  const backwards = event.shiftKey === true;
  if ((!backwards && current === controls.length - 1) || (backwards && current <= 0)) {
    focus(backwards ? controls[controls.length - 1] : controls[0]);
    preventDefault(event);
  }
}

function handlePointerMove(root, event) {
  if (isFrozen(root)) return;
  const probe = closestWithin(event?.target, CHART_PROBE_SELECTOR, root);
  if (!probe) return;
  const surface = closestWithin(probe, SURFACE_SELECTOR, root);
  if (!surface) return;
  const point = closestWithin(event.target, CHART_POINT_SELECTOR, probe) || nearestChartPoint(probe, event);
  if (point) showChartPoint(probe, point, surface);
}

function positionSourceCitationPopup(root, event) {
  if (isFrozen(root)) return;
  const group = closestWithin(event?.target, SOURCE_CITATION_GROUP_SELECTOR, root);
  if (!group || typeof group.getBoundingClientRect !== "function") return;
  const popup = queryOne(group, SOURCE_CITATION_SUPPORTING_SELECTOR);
  if (!popup) return;

  const viewportWidth = sourcePopupViewportWidth(root);
  if (!(viewportWidth > 0)) return;
  const viewportInset = 12;
  const rect = group.getBoundingClientRect();
  const visualScale = sourcePopupVisualScale(root, group, rect);
  const maximumLocalPopupWidth = Math.max(0, (viewportWidth - (viewportInset * 2)) / visualScale);
  const localPopupWidth = Math.min(320, maximumLocalPopupWidth);
  const popupWidth = localPopupWidth * visualScale;
  const groupLeft = Number(rect?.left || 0);
  const groupWidth = Number(rect?.width || 0);
  const groupRight = Number.isFinite(Number(rect?.right)) ? Number(rect.right) : groupLeft + groupWidth;
  const preferredViewportLeft = groupRight - popupWidth;
  const maximumViewportLeft = Math.max(viewportInset, viewportWidth - viewportInset - popupWidth);
  const viewportLeft = Math.max(viewportInset, Math.min(maximumViewportLeft, preferredViewportLeft));
  setStyleProperty(popup, "--scopy-source-popup-max-width", `${maximumLocalPopupWidth}px`);
  setStyleProperty(popup, "--scopy-source-popup-left", `${(viewportLeft - groupLeft) / visualScale}px`);
}

function sourcePopupVisualScale(root, group, groupRect) {
  const rootRect = typeof root?.getBoundingClientRect === "function" ? root.getBoundingClientRect() : null;
  const rootVisualWidth = Number(rootRect?.width || 0);
  const rootLocalWidth = Number(root?.offsetWidth || root?.clientWidth || 0);
  if (rootVisualWidth > 0 && rootLocalWidth > 0) return rootVisualWidth / rootLocalWidth;

  const groupVisualWidth = Number(groupRect?.width || 0);
  const groupLocalWidth = Number(group?.offsetWidth || group?.clientWidth || 0);
  if (groupVisualWidth > 0 && groupLocalWidth > 0) return groupVisualWidth / groupLocalWidth;
  return 1;
}

function sourcePopupViewportWidth(root) {
  const documentWidth = Number(root?.ownerDocument?.documentElement?.clientWidth || 0);
  if (documentWidth > 0) return documentWidth;
  if (typeof window !== "undefined") {
    const windowWidth = Number(window.innerWidth || 0);
    if (windowWidth > 0) return windowWidth;
  }
  if (root && typeof root.getBoundingClientRect === "function") {
    return Number(root.getBoundingClientRect()?.width || 0);
  }
  return 0;
}

function handlePointerLeave(root, event) {
  const probe = closestWithin(event?.target, CHART_PROBE_SELECTOR, root);
  if (!probe) return;
  if (event?.relatedTarget && contains(probe, event.relatedTarget)) return;
  hideChartTooltip(probe);
}

function nearestChartPoint(probe, event) {
  const points = chartPoints(probe);
  if (points.length === 0 || typeof probe.getBoundingClientRect !== "function") return null;
  const rect = probe.getBoundingClientRect();
  const width = Number(rect?.width || 0);
  const clientX = Number(event?.clientX);
  if (!(width > 0) || !Number.isFinite(clientX)) return points[0];
  const ratio = Math.max(0, Math.min(1, (clientX - Number(rect.left || 0)) / width));
  return points[Math.round(ratio * (points.length - 1))];
}

function moveChartPoint(probe, key, event, surface) {
  if (!["ArrowLeft", "ArrowRight", "Home", "End", "Escape"].includes(key)) return;
  if (key === "Escape") {
    hideChartTooltip(probe);
    preventDefault(event);
    return;
  }
  const points = chartPoints(probe);
  if (points.length === 0) return;
  const state = surfaceState.get(surface);
  let index = state?.chartPointIndex?.get(probe) ?? 0;
  if (key === "Home") index = 0;
  else if (key === "End") index = points.length - 1;
  else if (key === "ArrowLeft") index = Math.max(0, index - 1);
  else index = Math.min(points.length - 1, index + 1);
  showChartPoint(probe, points[index], surface);
  preventDefault(event);
}

function showChartPoint(probe, point, surface) {
  const points = chartPoints(probe);
  const fallback = points.indexOf(point);
  const index = boundedIndex(getAttribute(point, "data-scopy-point-index") || getAttribute(point, "data-scopy-index"), points.length) ?? Math.max(0, fallback);
  const label = getAttribute(point, "data-scopy-label") || "";
  const display = getAttribute(point, "data-scopy-display") || "";
  const tooltip = queryOne(probe, CHART_TOOLTIP_SELECTOR);
  if (!tooltip) return;
  setText(queryOne(tooltip, "[data-scopy-tooltip-label]"), label);
  setText(queryOne(tooltip, "[data-scopy-tooltip-display]"), display);
  setHidden(tooltip, false);
  setAttribute(tooltip, "aria-hidden", "false");
  setAttribute(probe, "data-scopy-active-point-index", String(index));
  if (point.id) setAttribute(probe, "aria-activedescendant", point.id);
  const state = surfaceState.get(surface) || { lightboxOpener: null, chartPointIndex: new WeakMap() };
  state.chartPointIndex.set(probe, index);
  surfaceState.set(surface, state);
}

function hideChartTooltips(surface) {
  for (const probe of queryAll(surface, CHART_PROBE_SELECTOR)) hideChartTooltip(probe);
}

function hideChartTooltip(probe) {
  const tooltip = queryOne(probe, CHART_TOOLTIP_SELECTOR);
  if (tooltip) {
    setHidden(tooltip, true);
    setAttribute(tooltip, "aria-hidden", "true");
  }
  removeAttribute(probe, "data-scopy-active-point-index");
  removeAttribute(probe, "aria-activedescendant");
}

function chartPoints(probe) {
  return queryAll(probe, CHART_POINT_SELECTOR).filter((node, index, values) => values.indexOf(node) === index);
}

function isLightboxOpen(surface) {
  const overlay = queryOne(surface, LIGHTBOX_SELECTOR);
  return Boolean(overlay && !overlay.hidden && getAttribute(overlay, "aria-hidden") !== "true");
}

function isFrozen(root) {
  return hydratedRoots.get(root)?.exportMode === true || getAttribute(root, "data-scopy-interaction-frozen") === "true";
}

function surfacesWithin(root) {
  const surfaces = queryAll(root, SURFACE_SELECTOR);
  if (typeof root.matches === "function" && root.matches(SURFACE_SELECTOR)) surfaces.unshift(root);
  return surfaces.filter((node, index, values) => values.indexOf(node) === index);
}

function indexedNodeValue(node, fallback) {
  const value = boundedIndex(getAttribute(node, "data-scopy-index"), Number.MAX_SAFE_INTEGER);
  return value == null ? fallback : value;
}

function boundedIndex(value, upperBound) {
  if (!/^\d+$/.test(String(value ?? ""))) return null;
  const index = Number(value);
  return Number.isSafeInteger(index) && index >= 0 && index < upperBound ? index : null;
}

function parseDecimal(value) {
  const raw = String(value ?? "").trim();
  if (raw.length === 0 || raw.length > MAX_DECIMAL_LENGTH) return null;
  const groupingValid = !raw.includes(",") ||
    /^[+-]?(?:\d{1,3}(?:,\d{3})+)(?:\.\d*)?$/.test(raw);
  const normalized = raw.replaceAll(",", "");
  if (!groupingValid || !DECIMAL_PATTERN.test(normalized)) return null;
  const number = Number(normalized);
  return Number.isFinite(number) ? number : null;
}

function parseFractionDigits(value) {
  if (!/^\d+$/.test(String(value ?? ""))) return 2;
  return Math.max(0, Math.min(MAX_FRACTION_DIGITS, Number(value)));
}

function formatDecimal(value, fractionDigits) {
  const normalized = Math.abs(value) < 0.5 * (10 ** -fractionDigits) ? 0 : value;
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
    useGrouping: true
  }).format(normalized);
}

function isOfflineImageSource(value) {
  const source = String(value || "");
  return /^data:image\/(?:png|jpeg|gif|webp);base64,[a-z0-9+/]+={0,2}$/i.test(source) ||
    /^rich\/[a-z0-9][a-z0-9-]*\.(?:png|jpe?g)$/i.test(source);
}

function reportHeight() {
  try {
    if (typeof window !== "undefined" && typeof window.__scopyReportHeight === "function") {
      window.__scopyReportHeight(true);
    }
  } catch {
    // Height reporting is best-effort and never owns interaction state.
  }
}

function isEventRoot(root) {
  return Boolean(root && typeof root.addEventListener === "function" && typeof root.removeEventListener === "function" && typeof root.querySelectorAll === "function");
}

function closestWithin(node, selector, boundary) {
  if (!node || typeof node.closest !== "function") return null;
  const match = node.closest(selector);
  if (!match) return null;
  if (!boundary || match === boundary || contains(boundary, match)) return match;
  return null;
}

function contains(root, node) {
  return root === node || (typeof root.contains === "function" && root.contains(node));
}

function queryAll(root, selector) {
  return root && typeof root.querySelectorAll === "function" ? Array.from(root.querySelectorAll(selector)) : [];
}

function queryOne(root, selector) {
  return root && typeof root.querySelector === "function" ? root.querySelector(selector) : null;
}

function getAttribute(node, name) {
  return node && typeof node.getAttribute === "function" ? node.getAttribute(name) : null;
}

function setAttribute(node, name, value) {
  if (node && typeof node.setAttribute === "function") node.setAttribute(name, String(value));
}

function removeAttribute(node, name) {
  if (node && typeof node.removeAttribute === "function") node.removeAttribute(name);
}

function setHidden(node, hidden) {
  if (!node) return;
  node.hidden = hidden;
  if (hidden) setAttribute(node, "hidden", "");
  else removeAttribute(node, "hidden");
}

function setText(node, value) {
  if (node) node.textContent = String(value ?? "");
}

function setStyleProperty(node, name, value) {
  if (node?.style && typeof node.style.setProperty === "function") {
    node.style.setProperty(name, String(value));
  }
}

function focus(node) {
  if (node && typeof node.focus === "function") node.focus();
}

function preventDefault(event) {
  if (event && typeof event.preventDefault === "function") event.preventDefault();
}
