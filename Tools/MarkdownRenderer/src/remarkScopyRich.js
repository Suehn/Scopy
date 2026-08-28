import { scopyIcon } from "./scopyIcons.js";

const RICH_LANGUAGE = "scopy-rich";
const MAX_BLOCK_BYTES = 1_024 * 1_024;
const MAX_JSON_DEPTH = 8;
const MAX_ITEMS = 20;
const MAX_IMAGES = 12;
const MAX_DAYS = 10;
const MAX_HOURLY_PER_DAY = 24;
const MAX_SERIES = 8;
const MAX_METRICS = 16;
const MAX_POINTS_PER_SERIES = 256;
const MAX_TOTAL_FINANCE_POINTS = 1_024;
const MAX_STRING_SCALARS = 4_096;
const MAX_URL_LENGTH = 2_048;
const MAX_DATA_IMAGE_BYTES = 256 * 1_024;
const MAX_TOTAL_DATA_IMAGE_BYTES = 512 * 1_024;
const VALID_TYPES = new Set([
  "news",
  "web_results",
  "image_group",
  "weather",
  "finance",
  "currency"
]);
const VALID_STATES = new Set(["ready", "partial", "empty", "error"]);
const VALID_IMAGE_LAYOUTS = new Set(["search", "carousel", "full_width"]);
const VALID_UNITS = new Set(["F", "C"]);
const VALID_TRENDS = new Set(["up", "down", "flat"]);
const COMMON_KEYS = ["version", "type", "title", "state", "message", "source", "sourceUrl", "asOf"];

const BUNDLED_IMAGE_ASSETS = Object.freeze({
  "news-openai-hugging-face": "rich/news-openai-hugging-face.jpg",
  "news-openai-jalapeno": "rich/news-openai-jalapeno.jpg",
  "news-openai-kiro": "rich/news-openai-kiro.jpg",
  "image-group-chatgpt-search-button": "rich/image-group-chatgpt-search-button.jpg",
  "image-group-chatgpt-search-results": "rich/image-group-chatgpt-search-results.jpg",
  "weather-mostly-cloudy-light": "rich/weather-mostly-cloudy-light.png",
  "weather-sun-shower-light": "rich/weather-sun-shower-light.png",
  "favicon-help-openai-32": "rich/favicon-help-openai-32.png",
  "favicon-investing-32": "rich/favicon-investing-32.png",
  "favicon-openai-32": "rich/favicon-openai-32.png",
  "favicon-reuters-32": "rich/favicon-reuters-32.png"
});

export function remarkScopyRich() {
  return function transformer(tree) {
    visit(tree, (node, parent, index) => {
      if (!parent || index < 0 || node?.type !== "code" || node.lang !== RICH_LANGUAGE || String(node.meta || "").trim()) {
        return;
      }
      const surface = parseRichSurface(node.value);
      if (!surface) return;
      parent.children[index] = {
        type: "scopyRich",
        surface,
        position: node.position
      };
    });
  };
}

export function remarkScopyRichOrdinals() {
  return function transformer(tree) {
    let ordinal = 0;
    visit(tree, (node) => {
      if (node?.type === "code" && node.lang === RICH_LANGUAGE) {
        ordinal += 1;
        return;
      }
      if (node?.type !== "scopyRich" && node?.type !== "scopyImageGroup") return;
      const type = node.type === "scopyRich" ? node.surface.type : "image_group";
      node.scopyRootID = "scopy-rich-" + type + "-" + ordinal;
      ordinal += 1;
    });
  };
}

export function scopyRichHandler(_state, node) {
  return renderSurface({ ...node.surface, rootID: node.scopyRootID });
}

export function scopyImageGroupHandler(_state, node) {
  const images = Array.isArray(node.images) ? node.images.map(normalizeAutomaticImage).filter(Boolean) : [];
  if (images.length < 2) return text("");
  return renderImageGroup({
    version: 2,
    type: "image_group",
    state: "ready",
    layout: images.length === 2 ? "search" : "carousel",
    initialIndex: 0,
    images,
    rootID: node.scopyRootID
  }, true);
}

export function isSafeHTTPURL(value) {
  if (typeof value !== "string" || value.length === 0 || unicodeScalarLength(value) > MAX_URL_LENGTH) {
    return false;
  }
  if (value !== value.trim() || /[\u0000-\u001f\u007f]/u.test(value)) {
    return false;
  }
  try {
    const decoded = decodeURIComponent(value);
    if (/[\u0000-\u001f\u007f]/u.test(decoded)) return false;
    const url = new URL(value);
    return (url.protocol === "http:" || url.protocol === "https:") && Boolean(url.hostname) && !url.username && !url.password;
  } catch {
    return false;
  }
}

export function isRenderableDataImage(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  const match = /^data:image\/(png|jpeg|webp|gif);base64,([A-Za-z0-9+/]+={0,2})$/i.exec(value);
  return Boolean(match && match[2].length % 4 === 0 && base64DecodedLength(match[2]) <= MAX_DATA_IMAGE_BYTES);
}

function parseRichSurface(value) {
  if (typeof value !== "string" || value.length === 0 || utf8Length(value) > MAX_BLOCK_BYTES) {
    return null;
  }
  let input;
  try {
    input = JSON.parse(value);
  } catch {
    return null;
  }
  if (!isRecord(input) ||
      exceedsJSONDepth(input, MAX_JSON_DEPTH) ||
      input.version !== 2 ||
      typeof input.type !== "string" ||
      !VALID_TYPES.has(input.type) ||
      !hasOnlyKeys(input, rootKeysForType(input.type))) {
    return null;
  }
  const common = normalizeCommon(input);
  if (!common) return null;
  if (common.state === "empty" || common.state === "error") {
    return common.message && hasOnlyKeys(input, COMMON_KEYS) ? common : null;
  }

  let surface = null;
  switch (input.type) {
    case "news":
    case "web_results":
      surface = normalizeResults(input, common);
      break;
    case "image_group":
      surface = normalizeImageGroup(input, common);
      break;
    case "weather":
      surface = normalizeWeather(input, common);
      break;
    case "finance":
      surface = normalizeFinance(input, common);
      break;
    case "currency":
      surface = normalizeCurrency(input, common);
      break;
    default:
      return null;
  }
  return surface && totalDataImageBytes(surface) <= MAX_TOTAL_DATA_IMAGE_BYTES ? surface : null;
}

function normalizeCommon(input) {
  const result = { version: 2, type: input.type };
  for (const key of ["title", "message", "source", "asOf"]) {
    if (input[key] === undefined) continue;
    const value = boundedString(input[key]);
    if (value == null) return null;
    result[key] = value;
  }
  if (input.state !== undefined) {
    if (typeof input.state !== "string" || !VALID_STATES.has(input.state)) return null;
    result.state = input.state;
  } else {
    result.state = "ready";
  }
  if (input.sourceUrl !== undefined) {
    if (!isSafeHTTPURL(input.sourceUrl)) return null;
    result.sourceUrl = input.sourceUrl;
  }
  return result;
}

function normalizeResults(input, common) {
  const items = normalizeArray(input.items, MAX_ITEMS, (item) => {
    if (!isRecord(item) || !hasOnlyKeys(item, ["title", "url", "source", "date", "snippet", "image", "favicon"])) {
      return null;
    }
    const title = boundedString(item.title);
    if (title == null || !isSafeHTTPURL(item.url)) return null;
    const result = { title, url: item.url };
    for (const key of ["source", "date", "snippet"]) {
      if (item[key] === undefined) continue;
      const value = boundedString(item[key]);
      if (value == null) return null;
      result[key] = value;
    }
    for (const key of ["image", "favicon"]) {
      if (item[key] === undefined) continue;
      const image = normalizeImageReference(item[key]);
      if (!image) return null;
      result[key] = image;
    }
    return result;
  }, common.state === "ready" ? 1 : 0);
  return items ? { ...common, items } : null;
}

function normalizeImageGroup(input, common) {
  if (typeof input.layout !== "string" || !VALID_IMAGE_LAYOUTS.has(input.layout)) return null;
  const images = normalizeArray(input.images, MAX_IMAGES, normalizeImageItem, 1);
  if (!images) return null;
  const initialIndex = input.initialIndex === undefined ? 0 : boundedInteger(input.initialIndex, 0, images.length - 1);
  return initialIndex == null ? null : { ...common, layout: input.layout, initialIndex, images };
}

function normalizeWeather(input, common) {
  const location = boundedString(input.location);
  if (location == null || !VALID_UNITS.has(input.selectedUnit)) return null;
  const days = normalizeArray(input.days, MAX_DAYS, normalizeWeatherDay, 1);
  if (!days) return null;
  const selectedDay = boundedInteger(input.selectedDay, 0, days.length - 1);
  return selectedDay == null ? null : {
    ...common,
    location,
    selectedUnit: input.selectedUnit,
    selectedDay,
    days
  };
}

function normalizeWeatherDay(input) {
  if (!isRecord(input) ||
      !hasOnlyKeys(input, ["label", "condition", "icon", "current", "high", "low", "hourly"])) {
    return null;
  }
  const label = boundedString(input.label);
  const condition = boundedString(input.condition);
  const current = normalizeDisplayPair(input.current);
  const high = normalizeDisplayPair(input.high);
  const low = normalizeDisplayPair(input.low);
  const hourly = normalizeArray(input.hourly, MAX_HOURLY_PER_DAY, normalizeWeatherHour, 2);
  if (label == null || condition == null || !current || !high || !low || !hourly) return null;
  const result = { label, condition, current, high, low, hourly };
  if (input.icon !== undefined) {
    const icon = normalizeImageReference(input.icon);
    if (!icon) return null;
    result.icon = icon;
  }
  return result;
}

function normalizeWeatherHour(input) {
  if (!isRecord(input) || !hasOnlyKeys(input, ["label", "temperature", "value"])) return null;
  const label = boundedString(input.label);
  const temperature = normalizeDisplayPair(input.temperature);
  const value = normalizeNumberPair(input.value);
  return label == null || !temperature || !value ? null : { label, temperature, value };
}

function normalizeFinance(input, common) {
  if (!isRecord(input.asset) ||
      !hasOnlyKeys(input.asset, ["name", "ticker"]) ||
      !isRecord(input.quote) ||
      !hasOnlyKeys(input.quote, ["price", "afterHours"])) {
    return null;
  }
  const name = boundedString(input.asset.name);
  const price = boundedString(input.quote.price);
  if (name == null || price == null) return null;
  const asset = { name };
  if (input.asset.ticker !== undefined) {
    const ticker = boundedString(input.asset.ticker);
    if (ticker == null) return null;
    asset.ticker = ticker;
  }
  const quote = { price };
  if (input.quote.afterHours !== undefined) {
    const afterHours = normalizeAfterHours(input.quote.afterHours);
    if (!afterHours) return null;
    quote.afterHours = afterHours;
  }
  const selectedRange = boundedString(input.selectedRange);
  if (selectedRange == null) return null;
  const series = normalizeArray(input.series, MAX_SERIES, normalizeFinanceSeries, 1);
  if (!series ||
      !series.some((entry) => entry.label === selectedRange) ||
      new Set(series.map((entry) => entry.label)).size !== series.length ||
      series.reduce((sum, entry) => sum + entry.points.length, 0) > MAX_TOTAL_FINANCE_POINTS) {
    return null;
  }
  let metrics = [];
  if (input.metrics !== undefined) {
    metrics = normalizeArray(input.metrics, MAX_METRICS, (item) => {
      return isRecord(item) && hasOnlyKeys(item, ["label", "value"])
        ? requiredStrings(item, ["label", "value"])
        : null;
    });
    if (!metrics) return null;
  }
  return { ...common, asset, quote, selectedRange, series, metrics };
}

function normalizeAfterHours(input) {
  if (!isRecord(input) || !hasOnlyKeys(input, ["price", "change", "changePercent", "label", "trend"])) {
    return null;
  }
  const result = requiredStrings(input, ["price", "change", "changePercent", "label"]);
  if (!result || !VALID_TRENDS.has(input.trend)) return null;
  result.trend = input.trend;
  return result;
}

function normalizeFinanceSeries(input) {
  if (!isRecord(input) ||
      !hasOnlyKeys(input, ["label", "dateRange", "change", "changePercent", "trend", "points"])) {
    return null;
  }
  const result = requiredStrings(input, ["label", "dateRange", "change", "changePercent"]);
  if (!result || !VALID_TRENDS.has(input.trend)) return null;
  const points = normalizeArray(input.points, MAX_POINTS_PER_SERIES, (point) => {
    if (!isRecord(point) || !hasOnlyKeys(point, ["label", "value", "displayValue"])) return null;
    const label = boundedString(point.label);
    const displayValue = point.displayValue === undefined ? String(point.value) : boundedString(point.displayValue);
    if (label == null || displayValue == null || typeof point.value !== "number" || !Number.isFinite(point.value)) {
      return null;
    }
    return { label, value: point.value, displayValue };
  }, 2);
  return points ? { ...result, trend: input.trend, points } : null;
}

function normalizeCurrency(input, common) {
  if (!isRecord(input.from) || !isRecord(input.to)) return null;
  const from = normalizeCurrencyIdentity(input.from);
  const to = normalizeCurrencyIdentity(input.to);
  const amount = boundedNumber(input.amount, 0, 1e15);
  const rate = boundedNumber(input.rate, Number.MIN_VALUE, 1e12);
  const fractionDigits = boundedInteger(input.fractionDigits, 0, 8);
  return !from || !to || amount == null || rate == null || fractionDigits == null
    ? null
    : { ...common, from, to, amount, rate, fractionDigits };
}

function normalizeCurrencyIdentity(input) {
  if (!hasOnlyKeys(input, ["code", "name", "symbol", "flag"])) return null;
  const result = requiredStrings(input, ["code"]);
  if (!result) return null;
  for (const key of ["name", "symbol", "flag"]) {
    if (input[key] === undefined) continue;
    const value = boundedString(input[key]);
    if (value == null) return null;
    result[key] = value;
  }
  return result;
}

function normalizeDisplayPair(input) {
  if (!isRecord(input) || !hasOnlyKeys(input, ["f", "c"])) return null;
  return requiredStrings(input, ["f", "c"]);
}

function normalizeNumberPair(input) {
  if (!isRecord(input) || !hasOnlyKeys(input, ["f", "c"])) return null;
  const f = boundedNumber(input.f, -500, 1_000);
  const c = boundedNumber(input.c, -500, 1_000);
  return f == null || c == null ? null : { f, c };
}

function normalizeImageItem(input) {
  if (!isRecord(input) ||
      !hasOnlyKeys(input, ["src", "asset", "alt", "title", "source", "sourceUrl"])) {
    return null;
  }
  const image = normalizeImageReference({
    ...(input.src === undefined ? {} : { src: input.src }),
    ...(input.asset === undefined ? {} : { asset: input.asset }),
    ...(input.alt === undefined ? {} : { alt: input.alt })
  });
  if (!image) return null;
  for (const key of ["title", "source"]) {
    if (input[key] === undefined) continue;
    const value = boundedString(input[key]);
    if (value == null) return null;
    image[key] = value;
  }
  if (input.sourceUrl !== undefined) {
    if (!isSafeHTTPURL(input.sourceUrl)) return null;
    image.sourceUrl = input.sourceUrl;
  }
  return image;
}

function normalizeImageReference(input) {
  if (!isRecord(input) || !hasOnlyKeys(input, ["src", "asset", "alt"])) return null;
  const hasSource = typeof input.src === "string";
  const hasAsset = typeof input.asset === "string";
  if (hasSource === hasAsset) return null;
  const result = {};
  if (hasAsset) {
    if (!Object.hasOwn(BUNDLED_IMAGE_ASSETS, input.asset)) return null;
    result.asset = input.asset;
  } else {
    if (!isSafeHTTPURL(input.src) && !isRenderableDataImage(input.src)) return null;
    result.src = input.src;
  }
  if (input.alt !== undefined) {
    const alt = boundedString(input.alt, true);
    if (alt == null) return null;
    result.alt = alt;
  }
  return result;
}

function normalizeAutomaticImage(input) {
  if (!isRecord(input)) return null;
  return normalizeImageItem({
    src: String(input.src || ""),
    alt: String(input.alt || ""),
    ...(input.title === undefined ? {} : { title: String(input.title) })
  });
}

function renderSurface(surface) {
  if (surface.state === "empty" || surface.state === "error") {
    return richSection(surface, [
      element("p", { className: ["scopy-rich-state-message"] }, [text(surface.message)])
    ], surfaceLabel(surface.type));
  }
  switch (surface.type) {
    case "news":
      return renderNews(surface);
    case "web_results":
      return renderWebResults(surface);
    case "image_group":
      return renderImageGroup(surface, false);
    case "weather":
      return renderWeather(surface);
    case "finance":
      return renderFinance(surface);
    case "currency":
      return renderCurrency(surface);
    default:
      return text("");
  }
}

function richSection(surface, children, label, properties = {}) {
  const boundary = surface.state === "partial" && surface.message
    ? element("p", { className: ["scopy-rich-boundary"] }, [text(surface.message)])
    : null;
  const provenance = renderProvenance(surface);
  return element("section", {
    id: surface.rootID,
    className: ["scopy-rich", "scopy-rich-" + surface.type.replace("_", "-")],
    dataType: surface.type,
    dataState: surface.state,
    dataScopyVersion: "2",
    dir: "auto",
    role: "region",
    ariaLabel: surface.title || label,
    ...properties
  }, [boundary, ...children, provenance].filter(Boolean));
}

function renderNews(surface) {
  const cards = surface.items.map((item, index) => {
    const media = item.image
      ? renderImageVisual(item.image, item.title, ["scopy-rich-news-media"])
      : null;
    const source = element("span", { className: ["scopy-rich-news-source"] }, [
      renderOriginIcon(item.favicon, item.source || "Source"),
      element("span", {}, [text(item.source || hostLabel(item.url))])
    ]);
    const body = element("span", { className: ["scopy-rich-news-body"] }, [
      source,
      element("span", { className: ["scopy-rich-news-title"] }, [text(item.title)]),
      item.date ? element("time", { className: ["scopy-rich-news-date"] }, [text(item.date)]) : null,
      item.snippet
        ? element("span", { className: ["scopy-visually-hidden"] }, [text(item.snippet)])
        : null
    ].filter(Boolean));
    return element("li", { className: ["scopy-rich-news-item"] }, [
      element("article", { id: surface.rootID + "-item-" + index, className: ["scopy-rich-news-card"] }, [
        element("a", {
          href: item.url,
          className: ["scopy-rich-news-link"],
          ariaLabel: item.title
        }, [media, body].filter(Boolean))
      ])
    ]);
  });
  return richSection(surface, [
    element("ol", {
      className: ["scopy-rich-news-track"],
      ariaLabel: surface.title || "News"
    }, cards)
  ], "News");
}

function renderWebResults(surface) {
  const items = surface.items.map((item, index) => {
    const source = item.source || hostLabel(item.url);
    return element("li", { className: ["scopy-rich-web-result"] }, [
      element("article", { id: surface.rootID + "-item-" + index }, [
        element("p", { className: ["scopy-rich-web-result-source"] }, [
          renderOriginIcon(item.favicon, source),
          text(source),
          item.date ? element("time", {}, [text(item.date)]) : null
        ].filter(Boolean)),
        element("h4", { className: ["scopy-rich-web-result-title"] }, [
          element("a", { href: item.url, className: ["scopy-rich-web-result-link"] }, [text(item.title)])
        ]),
        item.snippet
          ? element("p", { className: ["scopy-rich-web-result-snippet"] }, [text(item.snippet)])
          : null
      ].filter(Boolean))
    ]);
  });
  return richSection(surface, [
    element("ol", { className: ["scopy-rich-web-results"] }, items)
  ], "Web results");
}

function renderImageGroup(surface, automatic) {
  const figures = surface.images.map((image, index) => {
    const title = image.title || image.alt || "Image " + (index + 1);
    const source = image.source || "";
    const sourceLink = image.sourceUrl
      ? element("a", { href: image.sourceUrl, className: ["scopy-rich-image-source-link"] }, [text(source || "Source")])
      : source ? element("span", {}, [text(source)]) : null;
    const visualSource = imageRenderSource(image);
    const visual = renderImageVisual(image, title, ["scopy-rich-image"]);
    const inner = visualSource
        ? element("button", {
          type: "button",
          className: ["scopy-rich-image-button"],
          dataScopyAction: "lightbox-open",
          dataScopyIndex: String(index),
          dataScopyLightboxTitle: title,
          dataScopyLightboxSource: source,
          ariaLabel: "Open image " + (index + 1) + " of " + surface.images.length + ": " + title
        }, [visual])
      : visual;
    return element("figure", {
      id: surface.rootID + "-image-" + index,
      className: ["scopy-rich-image-item"],
      dataScopyImageIndex: String(index)
    }, [
      inner,
      element("figcaption", { className: ["scopy-visually-hidden"] }, [
        element("span", { dataScopyImageTitle: "true" }, [text(title)]),
        sourceLink
      ].filter(Boolean))
    ]);
  });
  const hasLightboxImages = surface.images.some((image) => Boolean(imageRenderSource(image)));
  const normalized = { ...surface, type: "image_group" };
  return richSection(normalized, [
    element("div", {
      className: [
        "scopy-rich-image-grid",
        "scopy-rich-image-layout-" + surface.layout
      ],
      role: "group",
      ariaLabel: automatic ? "Image group with " + surface.images.length + " images" : "Images"
    }, figures),
    hasLightboxImages ? renderLightbox(surface) : null
  ].filter(Boolean), "Image group", {
    dataScopyInteractive: hasLightboxImages ? "true" : "false",
    dataScopyLightboxIndex: String(surface.initialIndex || 0)
  });
}

function renderLightbox(surface) {
  return element("div", {
    className: ["scopy-rich-lightbox"],
    dataScopyLightbox: "true",
    hidden: true,
    role: "dialog",
    ariaModal: "true",
    ariaLabel: "Image viewer"
  }, [
    element("button", {
      type: "button",
      className: ["scopy-rich-lightbox-close"],
      dataScopyAction: "lightbox-close",
      ariaLabel: "Close image viewer"
    }, [scopyIcon("close")]),
    element("button", {
      type: "button",
      className: ["scopy-rich-lightbox-previous"],
      dataScopyAction: "lightbox-prev",
      ariaLabel: "Previous image"
    }, [scopyIcon("caret-left")]),
    element("div", { className: ["scopy-rich-lightbox-stage"] }, [
      element("img", {
        className: ["scopy-rich-lightbox-image"],
        alt: "",
        dataScopyDeferredImage: "true",
        dataScopyLightboxImage: "true"
      }, [])
    ]),
    element("button", {
      type: "button",
      className: ["scopy-rich-lightbox-next"],
      dataScopyAction: "lightbox-next",
      ariaLabel: "Next image"
    }, [scopyIcon("caret-right")]),
    element("p", {
      className: ["scopy-rich-lightbox-counter"],
      dataScopyLightboxCounter: "true",
      ariaLive: "polite"
    }, [text("1 / " + surface.images.length)]),
    element("div", { className: ["scopy-rich-lightbox-meta"] }, [
      element("p", { dataScopyLightboxSource: "true" }, []),
      element("p", { dataScopyLightboxTitle: "true" }, [])
    ])
  ]);
}

function renderWeather(surface) {
  const currentPanels = surface.days.map((day, index) => {
    const selected = index === surface.selectedDay;
    return element("div", {
      id: surface.rootID + "-weather-current-" + index,
      className: ["scopy-rich-weather-current-panel"],
      dataScopyWeatherPanel: String(index),
      dataScopyIndex: String(index),
      hidden: !selected,
      role: "tabpanel",
      ariaLabelledBy: surface.rootID + "-day-" + index
    }, [
      element("div", { className: ["scopy-rich-weather-current-row"] }, [
        element("p", { className: ["scopy-rich-weather-current-value"] }, temperatureNodes(day.current, surface.selectedUnit)),
        renderWeatherUnitButton(surface.selectedUnit)
      ]),
      element("p", { className: ["scopy-rich-weather-summary"] }, [text(day.condition)])
    ]);
  });

  const dayButtons = surface.days.map((day, index) => {
    const selected = index === surface.selectedDay;
    return element("button", {
      id: surface.rootID + "-day-" + index,
      type: "button",
      className: ["scopy-rich-weather-day"],
      dataScopyAction: "weather-day",
      dataScopyIndex: String(index),
      role: "tab",
      ariaSelected: selected ? "true" : "false",
      ariaPressed: selected ? "true" : "false",
      ariaControls: surface.rootID + "-weather-current-" + index,
      tabIndex: selected ? 0 : -1
    }, [
      element("span", { className: ["scopy-rich-weather-day-name"] }, [text(day.label)]),
      day.icon
        ? renderImageVisual(day.icon, day.condition, ["scopy-rich-weather-day-icon"])
        : element("span", { className: ["scopy-rich-weather-day-icon-placeholder"], ariaHidden: "true" }, []),
      element("span", { className: ["scopy-rich-weather-day-high"] }, temperatureNodes(day.high, surface.selectedUnit)),
      element("span", { className: ["scopy-rich-weather-day-low"] }, temperatureNodes(day.low, surface.selectedUnit))
    ]);
  });

  const chartPanels = surface.days.map((day, index) => {
    const selected = index === surface.selectedDay;
    return element("div", {
      className: ["scopy-rich-weather-chart-panel"],
      dataScopyWeatherPanel: String(index),
      dataScopyIndex: String(index),
      hidden: !selected
    }, [
      renderWeatherChart(day, "F", surface.rootID, index, surface.selectedUnit),
      renderWeatherChart(day, "C", surface.rootID, index, surface.selectedUnit)
    ]);
  });

  return richSection(surface, [
    element("div", { className: ["scopy-rich-weather-card"] }, [
      element("p", { className: ["scopy-rich-weather-location"] }, [text(surface.location)]),
      element("div", { className: ["scopy-rich-weather-current-panels"] }, currentPanels),
      element("div", {
        className: ["scopy-rich-weather-days"],
        role: "tablist",
        ariaLabel: "Daily forecast"
      }, dayButtons),
      element("p", { className: ["scopy-rich-weather-chart-title"] }, [
        element("span", {}, [text("温度")]),
        scopyIcon("caret-up-down")
      ]),
      element("div", { className: ["scopy-rich-weather-chart-panels"] }, chartPanels)
    ])
  ], "Weather for " + surface.location, {
    dataScopyInteractive: "true",
    dataScopyUnit: surface.selectedUnit,
    dataScopyDayIndex: String(surface.selectedDay)
  });
}

function renderWeatherUnitButton(selectedUnit) {
  return element("span", {
    className: ["scopy-rich-weather-unit"],
    role: "group",
    ariaLabel: "Temperature unit"
  }, [
    ...["F", "C"].flatMap((unit, index) => [
      element("button", {
        type: "button",
        className: ["scopy-rich-weather-unit-option"],
        dataScopyAction: "weather-unit",
        dataScopyUnit: unit,
        ariaPressed: selectedUnit === unit ? "true" : "false",
        ariaLabel: unit === "F" ? "华氏度" : "摄氏度",
        tabIndex: selectedUnit === unit ? 0 : -1
      }, [text(unit)]),
      index === 0 ? element("span", { ariaHidden: "true" }, [text(" / ")]) : null
    ].filter(Boolean))
  ]);
}

function renderWeatherChart(day, unit, rootID, dayIndex, selectedUnit) {
  const points = day.hourly.map((hour) => ({
    label: hour.label,
    value: hour.value[unit.toLowerCase()],
    displayValue: hour.temperature[unit.toLowerCase()]
  }));
  const chartWidth = Math.max(768, points.length * 96);
  const chartHeight = 120;
  const gradientID = rootID + "-weather-gradient-" + dayIndex + "-" + unit.toLowerCase();
  const geometry = chartGeometry(points, chartWidth, chartHeight, {
    left: 52,
    right: 44,
    top: 24,
    bottom: 28
  });
  const pointNodes = geometry.coordinates.map((point, index) =>
    element("g", {}, [
      element("text", {
        x: point.x,
        y: point.y - 10,
        className: ["scopy-rich-weather-chart-value"],
        textAnchor: "middle"
      }, [text(points[index].displayValue)]),
      element("circle", {
        cx: point.x,
        cy: point.y,
        r: 4,
        className: ["scopy-rich-chart-dot"],
        dataScopyChartPoint: "true",
        dataScopyIndex: String(index),
        dataScopyX: String(point.x),
        dataScopyLabel: points[index].label,
        dataScopyDisplay: points[index].displayValue
      }, []),
      element("text", {
        x: point.x,
        y: 116,
        className: ["scopy-rich-weather-chart-time"],
        textAnchor: "middle"
      }, [text(points[index].label)])
    ])
  );
  return element("figure", {
    className: ["scopy-rich-weather-chart"],
    dataScopyUnitValue: unit,
    hidden: unit !== selectedUnit,
    dataScopyAction: "chart-probe",
    dataScopyChartCount: String(points.length),
    tabIndex: 0,
    role: "img",
    ariaLabel: day.label + " hourly temperature in " + unit
  }, [
    element("svg", {
      viewBox: "0 0 " + chartWidth + " " + chartHeight,
      width: chartWidth,
      height: chartHeight,
      ariaHidden: "true",
      focusable: "false"
    }, [
      renderChartGradient(gradientID, "#ee9340", 0.24),
      element("path", {
        d: geometry.areaPath,
        fill: "url(#" + gradientID + ")",
        className: ["scopy-rich-weather-chart-area"]
      }, []),
      element("path", {
        d: geometry.linePath,
        fill: "none",
        className: ["scopy-rich-weather-chart-line"]
      }, []),
      ...pointNodes
    ]),
    renderChartTooltip(),
    renderAccessiblePointList(points)
  ]);
}

function renderFinance(surface) {
  const selectedIndex = surface.series.findIndex((entry) => entry.label === surface.selectedRange);
  const assetHeading = [surface.asset.name, surface.asset.ticker].filter(Boolean).join(" ");
  const summaries = surface.series.map((series, index) => {
    const selected = index === selectedIndex;
    return element("div", {
      className: ["scopy-rich-finance-summary", "scopy-rich-trend-" + series.trend],
      dataScopyFinancePanel: String(index),
      dataScopyIndex: String(index),
      hidden: !selected
    }, [
      element("p", { className: ["scopy-rich-finance-change"] }, [
        text(series.change + " (" + series.changePercent + ")")
      ]),
      element("p", { className: ["scopy-rich-finance-date-range"] }, [text(series.dateRange)])
    ]);
  });
  const afterHours = surface.quote.afterHours;
  const rangeButtons = surface.series.map((series, index) => {
    const selected = index === selectedIndex;
    return element("button", {
      id: surface.rootID + "-range-" + index,
      type: "button",
      className: ["scopy-rich-finance-range"],
      dataScopyAction: "finance-range",
      dataScopyIndex: String(index),
      role: "radio",
      ariaChecked: selected ? "true" : "false",
      tabIndex: selected ? 0 : -1
    }, [text(series.label)]);
  });
  const charts = surface.series.map((series, index) =>
    element("div", {
      className: ["scopy-rich-finance-chart-panel"],
      dataScopyFinancePanel: String(index),
      dataScopyIndex: String(index),
      hidden: index !== selectedIndex
    }, [renderFinanceChart(series, surface.rootID, index, assetHeading)])
  );
  return richSection(surface, [
    element("div", { className: ["scopy-rich-finance-card"] }, [
      element("div", { className: ["scopy-rich-finance-header"] }, [
        element("p", { className: ["scopy-rich-finance-asset"] }, [
          text(surface.asset.name),
          surface.asset.ticker
            ? element("span", { className: ["scopy-rich-ltr"] }, [text(" (" + surface.asset.ticker + ")")])
            : null
        ].filter(Boolean)),
        element("p", { className: ["scopy-rich-finance-price"] }, [text(surface.quote.price)]),
        element("div", { className: ["scopy-rich-finance-summaries"] }, summaries),
        afterHours
          ? element("p", {
              className: ["scopy-rich-finance-after-hours", "scopy-rich-trend-" + afterHours.trend]
            }, [
              element("span", { className: ["scopy-rich-finance-after-hours-price"] }, [text(afterHours.price)]),
              text(" "),
              element("span", {}, [text(afterHours.change + " (" + afterHours.changePercent + ")")]),
              text(" "),
              element("span", { className: ["scopy-rich-finance-after-hours-label"] }, [text(afterHours.label)])
            ])
          : null
      ].filter(Boolean)),
      element("div", {
        className: ["scopy-rich-finance-ranges"],
        role: "radiogroup",
        ariaLabel: "Price range"
      }, rangeButtons),
      element("div", { className: ["scopy-rich-finance-charts"] }, charts),
      surface.metrics.length
        ? definitionList(surface.metrics.map((metric) => [metric.label, metric.value]), "scopy-rich-finance-metrics")
        : null
    ].filter(Boolean))
  ], "Finance for " + assetHeading, {
    dataScopyInteractive: "true",
    dataScopyRangeIndex: String(selectedIndex)
  });
}

function renderFinanceChart(series, rootID, seriesIndex, assetHeading) {
  const yTicks = numericTicks(series.points.map((point) => point.value), 5);
  const geometry = chartGeometry(
    series.points,
    738,
    240,
    { left: 8, right: 46, top: 14, bottom: 28 },
    { min: yTicks[0], max: yTicks.at(-1) }
  );
  const chartColor = series.trend === "up"
    ? "#4b9e53"
    : series.trend === "down" ? "#ef4146" : "#8f8f8f";
  const gradientID = rootID + "-finance-gradient-" + seriesIndex;
  const xTickIndexes = sampledIndexes(series.points.length, 7);
  const yLabels = yTicks.map((value) => {
    const y = valueToY(value, geometry.min, geometry.max, 14, 212);
    return element("g", {}, [
      element("path", {
        d: "M8 " + round(y) + " H692",
        fill: "none",
        className: ["scopy-rich-finance-grid-line"]
      }, []),
      element("text", {
        x: 700,
        y: round(y + 4),
        className: ["scopy-rich-finance-axis-label"]
      }, [text(formatAxisNumber(value))])
    ]);
  });
  const xLabels = xTickIndexes.map((index) => {
    const point = geometry.coordinates[index];
    return element("text", {
      x: point.x,
      y: 235,
      className: ["scopy-rich-finance-axis-label"],
      textAnchor: index === 0 ? "start" : index === series.points.length - 1 ? "end" : "middle"
    }, [text(series.points[index].label)]);
  });
  const points = geometry.coordinates.map((point, index) =>
    element("circle", {
      cx: point.x,
      cy: point.y,
      r: 8,
      className: ["scopy-rich-finance-hit-point"],
      dataScopyChartPoint: "true",
      dataScopyIndex: String(index),
      dataScopyX: String(point.x),
      dataScopyLabel: series.points[index].label,
      dataScopyDisplay: series.points[index].displayValue,
      tabIndex: -1
    }, [])
  );
  return element("figure", {
    className: ["scopy-rich-finance-chart", "scopy-rich-trend-" + series.trend],
    dataScopyAction: "chart-probe",
    dataScopyChartCount: String(series.points.length),
    tabIndex: 0,
    role: "img",
    ariaLabel: assetHeading + " " + series.label + " chart"
  }, [
    element("svg", { viewBox: "0 0 738 240", ariaHidden: "true", focusable: "false" }, [
      renderChartGradient(gradientID, chartColor, 0.24),
      ...yLabels,
      element("path", {
        d: geometry.areaPath,
        fill: "url(#" + gradientID + ")",
        className: ["scopy-rich-finance-chart-area"]
      }, []),
      element("path", {
        d: geometry.linePath,
        fill: "none",
        className: ["scopy-rich-finance-chart-line"]
      }, []),
      ...points,
      ...xLabels
    ]),
    renderChartTooltip(),
    renderAccessiblePointList(series.points)
  ]);
}

function renderChartGradient(id, color, topOpacity) {
  return element("defs", {}, [
    element("linearGradient", {
      id,
      x1: "0%",
      x2: "0%",
      y1: "0%",
      y2: "100%",
      gradientUnits: "objectBoundingBox"
    }, [
      element("stop", { offset: "0%", stopColor: color, stopOpacity: String(topOpacity) }, []),
      element("stop", { offset: "100%", stopColor: color, stopOpacity: "0" }, [])
    ])
  ]);
}

function renderCurrency(surface) {
  const result = surface.amount * surface.rate;
  return richSection(surface, [
    element("div", { className: ["scopy-rich-currency-card"] }, [
      renderCurrencyRow(surface.from, "from", surface.amount, surface.fractionDigits, surface.rootID),
      renderCurrencyRow(surface.to, "to", result, surface.fractionDigits, surface.rootID)
    ])
  ], "Currency conversion from " + surface.from.code + " to " + surface.to.code, {
    dataScopyInteractive: "true",
    dataScopyRate: String(surface.rate),
    dataScopyFractionDigits: String(surface.fractionDigits)
  });
}

function renderCurrencyRow(identity, side, value, fractionDigits, rootID) {
  const inputID = rootID + "-currency-" + side;
  const visibleName = identity.name || identity.code;
  return element("div", { className: ["scopy-rich-currency-row"] }, [
    element("label", { className: ["scopy-rich-currency-label"], htmlFor: inputID }, [
      identity.flag
        ? element("span", { className: ["scopy-rich-currency-flag"], ariaHidden: "true" }, [text(identity.flag)])
        : null,
      element("span", {}, [text(visibleName)])
    ].filter(Boolean)),
    element("div", { className: ["scopy-rich-currency-value"] }, [
      identity.symbol
        ? element("span", { className: ["scopy-rich-currency-symbol"], ariaHidden: "true" }, [text(identity.symbol)])
        : null,
      element("input", {
        id: inputID,
        type: "text",
        inputMode: "decimal",
        maxLength: 32,
        autoComplete: "off",
        spellCheck: "false",
        className: ["scopy-rich-currency-input"],
        dataScopyAction: "currency-input",
        dataScopyCurrencySide: side,
        value: formatDecimal(value, side === "from" ? null : fractionDigits),
        ariaLabel: identity.code + " amount"
      }, [])
    ])
  ]);
}

function renderChartTooltip() {
  return element("div", {
    className: ["scopy-rich-chart-tooltip"],
    dataScopyChartTooltip: "true",
    hidden: true,
    role: "status",
    ariaLive: "polite"
  }, [
    element("span", { dataScopyTooltipLabel: "true" }, []),
    element("strong", { dataScopyTooltipDisplay: "true" }, [])
  ]);
}

function renderAccessiblePointList(points) {
  return element("ol", { className: ["scopy-visually-hidden"] }, points.map((point) =>
    element("li", {}, [text(point.label + ": " + (point.displayValue ?? point.value))])
  ));
}

function renderOriginIcon(image, fallbackAlt) {
  if (image && imageRenderSource(image)) {
    return renderImageVisual(image, fallbackAlt, ["scopy-rich-origin-icon"]);
  }
  const icon = scopyIcon("globe");
  icon.properties.className.push("scopy-rich-origin-icon");
  return icon;
}

function renderImageVisual(image, fallbackAlt, classNames) {
  const alt = image.alt ?? fallbackAlt ?? "";
  const src = imageRenderSource(image);
  if (src) {
    return element("img", {
      src,
      alt,
      className: classNames,
      ...(isRenderableDataImage(src) ? { dataScopyTrustedImage: "true" } : {})
    }, []);
  }
  return element("span", {
    className: ["scopy-rich-image-placeholder", ...classNames],
    role: "img",
    ariaLabel: "Remote image unavailable offline: " + (alt || "image")
  }, [scopyIcon("image"), element("span", {}, [text(alt || "Image")])]);
}

function imageRenderSource(image) {
  if (image?.asset && Object.hasOwn(BUNDLED_IMAGE_ASSETS, image.asset)) {
    return BUNDLED_IMAGE_ASSETS[image.asset];
  }
  return image?.src && isRenderableDataImage(image.src) ? image.src : "";
}

function renderProvenance(surface) {
  const parts = [surface.source, surface.asOf].filter(Boolean);
  return parts.length
    ? element("p", { className: ["scopy-visually-hidden", "scopy-rich-provenance"] }, [text(parts.join(" · "))])
    : null;
}

function temperatureNodes(pair, selectedUnit) {
  return ["F", "C"].map((unit) =>
    element("span", {
      dataScopyUnitValue: unit,
      hidden: unit !== selectedUnit,
      className: ["scopy-rich-ltr"]
    }, [text(pair[unit.toLowerCase()])])
  );
}

function chartGeometry(points, width, height, padding, domain = null) {
  const values = points.map((point) => point.value);
  const rawMin = Math.min(...values);
  const rawMax = Math.max(...values);
  const rawSpan = rawMax - rawMin;
  const guard = rawSpan === 0 ? Math.max(Math.abs(rawMax) * 0.02, 1) : rawSpan * 0.08;
  const min = domain?.min ?? rawMin - guard;
  const max = domain?.max ?? rawMax + guard;
  const innerWidth = width - padding.left - padding.right;
  const innerHeight = height - padding.top - padding.bottom;
  const coordinates = points.map((point, index) => ({
    x: round(padding.left + (points.length === 1 ? innerWidth / 2 : (index / (points.length - 1)) * innerWidth)),
    y: round(padding.top + (1 - ((point.value - min) / (max - min))) * innerHeight)
  }));
  const linePath = coordinates.map((point, index) =>
    (index === 0 ? "M" : "L") + point.x + " " + point.y
  ).join(" ");
  const baseY = height - padding.bottom;
  const areaPath = "M" + coordinates[0].x + " " + baseY + " " +
    coordinates.map((point) => "L" + point.x + " " + point.y).join(" ") +
    " L" + coordinates.at(-1).x + " " + baseY + " Z";
  return { coordinates, linePath, areaPath, min, max };
}

function numericTicks(values, count) {
  const min = Math.min(...values);
  const max = Math.max(...values);
  if (min === max) return [min];
  const roughStep = (max - min) / Math.max(1, count - 1);
  const magnitude = 10 ** Math.floor(Math.log10(roughStep));
  const normalized = roughStep / magnitude;
  const factor = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  const step = factor * magnitude;
  const axisMin = Math.floor(min / step) * step;
  const axisMax = Math.ceil(max / step) * step;
  const ticks = [];
  for (let value = axisMin; value <= axisMax + step * 0.5; value += step) {
    ticks.push(round(value));
  }
  return ticks;
}

function sampledIndexes(length, count) {
  if (length <= count) return Array.from({ length }, (_, index) => index);
  const indexes = new Set();
  for (let index = 0; index < count; index += 1) {
    indexes.add(Math.round((index / (count - 1)) * (length - 1)));
  }
  return [...indexes].sort((a, b) => a - b);
}

function valueToY(value, min, max, top, bottom) {
  return bottom - ((value - min) / (max - min)) * (bottom - top);
}

function formatAxisNumber(value) {
  const magnitude = Math.abs(value);
  if (magnitude >= 1_000_000_000) return round(value / 1_000_000_000) + "B";
  if (magnitude >= 1_000_000) return round(value / 1_000_000) + "M";
  if (magnitude >= 1_000) return round(value / 1_000) + "K";
  return String(round(value));
}

function formatDecimal(value, fractionDigits) {
  if (fractionDigits == null) {
    return Number.isInteger(value) ? String(value) : String(round(value));
  }
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
    useGrouping: true
  }).format(value);
}

function definitionList(entries, className) {
  return element("dl", { className: [className] }, entries.map(([label, value]) =>
    element("div", {}, [
      element("dt", {}, [text(label)]),
      element("dd", {}, [text(value)])
    ])
  ));
}

function hostLabel(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "Source";
  }
}

function surfaceLabel(type) {
  return ({
    news: "News",
    web_results: "Web results",
    image_group: "Image group",
    weather: "Weather",
    finance: "Finance",
    currency: "Currency conversion"
  })[type] || "Rich content";
}

function rootKeysForType(type) {
  switch (type) {
    case "news":
    case "web_results":
      return [...COMMON_KEYS, "items"];
    case "image_group":
      return [...COMMON_KEYS, "layout", "initialIndex", "images"];
    case "weather":
      return [...COMMON_KEYS, "location", "selectedUnit", "selectedDay", "days"];
    case "finance":
      return [...COMMON_KEYS, "asset", "quote", "selectedRange", "series", "metrics"];
    case "currency":
      return [...COMMON_KEYS, "from", "to", "amount", "rate", "fractionDigits"];
    default:
      return COMMON_KEYS;
  }
}

function normalizeArray(value, max, normalizer, min = 0) {
  if (!Array.isArray(value) || value.length < min || value.length > max) return null;
  const result = [];
  for (const item of value) {
    const normalized = normalizer(item);
    if (normalized == null) return null;
    result.push(normalized);
  }
  return result;
}

function requiredStrings(input, keys) {
  const result = {};
  for (const key of keys) {
    const value = boundedString(input[key]);
    if (value == null) return null;
    result[key] = value;
  }
  return result;
}

function boundedString(value, allowEmpty = false) {
  return typeof value === "string" &&
    unicodeScalarLength(value) <= MAX_STRING_SCALARS &&
    (allowEmpty || value.length > 0) &&
    !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)
    ? value
    : null;
}

function boundedInteger(value, min, max) {
  return Number.isInteger(value) && value >= min && value <= max ? value : null;
}

function boundedNumber(value, min, max) {
  return typeof value === "number" && Number.isFinite(value) && value >= min && value <= max ? value : null;
}

function totalDataImageBytes(value) {
  let total = 0;
  const stack = [value];
  while (stack.length > 0) {
    const next = stack.pop();
    if (typeof next === "string") {
      const match = /^data:image\/(?:png|jpeg|webp|gif);base64,([A-Za-z0-9+/]+={0,2})$/i.exec(next);
      if (match) total += base64DecodedLength(match[1]);
      continue;
    }
    if (Array.isArray(next)) {
      stack.push(...next);
      continue;
    }
    if (isRecord(next)) stack.push(...Object.values(next));
  }
  return total;
}

function base64DecodedLength(payload) {
  if (!payload) return 0;
  const padding = payload.endsWith("==") ? 2 : payload.endsWith("=") ? 1 : 0;
  return Math.floor((payload.length * 3) / 4) - padding;
}

function exceedsJSONDepth(value, maxDepth) {
  const stack = [{ value, depth: 1 }];
  while (stack.length > 0) {
    const next = stack.pop();
    if (next.depth > maxDepth) return true;
    if (Array.isArray(next.value)) {
      for (const item of next.value) stack.push({ value: item, depth: next.depth + 1 });
    } else if (isRecord(next.value)) {
      for (const item of Object.values(next.value)) stack.push({ value: item, depth: next.depth + 1 });
    }
  }
  return false;
}

function utf8Length(value) {
  return new TextEncoder().encode(value).length;
}

function unicodeScalarLength(value) {
  return Array.from(value).length;
}

function round(value) {
  return Math.round(value * 100) / 100;
}

function element(tagName, properties = {}, children = []) {
  const clean = {};
  for (const [key, value] of Object.entries(properties)) {
    if (value !== undefined && value !== null) clean[key] = value;
  }
  return { type: "element", tagName, properties: clean, children };
}

function text(value) {
  return { type: "text", value: String(value) };
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(value, allowed) {
  const allowlist = new Set(allowed);
  return Object.keys(value).every((key) => allowlist.has(key));
}

function visit(node, visitor, parent = null) {
  if (!node) return;
  if (parent && Array.isArray(parent.children)) {
    const index = parent.children.indexOf(node);
    visitor(node, parent, index);
  } else {
    visitor(node, null, -1);
  }
  if (!Array.isArray(node.children)) return;
  for (const child of [...node.children]) visit(child, visitor, node);
}
