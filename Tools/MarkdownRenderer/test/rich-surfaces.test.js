import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { render } from "../src/render.js";
import { isRenderableDataImage } from "../src/remarkScopyRich.js";
import {
  BUNDLED_IMAGE_ASSETS,
  bundledImageAssetForExactRemoteURL
} from "../src/scopyLocalImageAssets.js";

const CODE_FENCE = /<pre><code class="(?:hljs )?language-scopy-rich">/;
const DATA_IMAGE = "data:image/png;base64,aGVsbG8=";
const previewAssetRoot = fileURLToPath(new URL("../../../Scopy/Resources/MarkdownPreview/", import.meta.url));

function rich(value) {
  return render(`\`\`\`scopy-rich\n${JSON.stringify(value)}\n\`\`\``).html;
}

function resultSurface(type, overrides = {}) {
  return {
    version: 2,
    type,
    title: type === "news" ? "Top stories" : "Web results",
    items: [{
      title: "A story",
      url: "https://example.com/story",
      source: "Example Wire",
      date: "Today",
      snippet: "A bounded summary.",
      image: { asset: "news-openai-hugging-face", alt: "Story photo" },
      favicon: { asset: "favicon-openai-32", alt: "" }
    }],
    ...overrides
  };
}

function weatherSurface(overrides = {}) {
  const hour = (label, f, c) => ({
    label,
    temperature: { f: `${f}°F`, c: `${c}°C` },
    value: { f, c }
  });
  const day = (label, condition, asset) => ({
    label,
    condition,
    icon: { asset, alt: condition },
    current: { f: "77°F", c: "25°C" },
    high: { f: "81°F", c: "27°C" },
    low: { f: "68°F", c: "20°C" },
    hourly: [hour("09:00", 75, 24), hour("12:00", 79, 26)]
  });
  return {
    version: 2,
    type: "weather",
    title: "Shanghai weather",
    location: "Shanghai",
    selectedUnit: "C",
    selectedDay: 0,
    days: [
      day("Mon", "Mostly cloudy", "weather-mostly-cloudy-light"),
      day("Tue", "Sun shower", "weather-sun-shower-light")
    ],
    ...overrides
  };
}

function financeSeries(label = "1D", pointCount = 2) {
  return {
    label,
    dateRange: `${label} range`,
    change: "+$1.00",
    changePercent: "+11.11%",
    trend: "up",
    points: Array.from({ length: pointCount }, (_, index) => ({
      label: `P${index}`,
      value: 9 + index,
      displayValue: `$${9 + index}.00`
    }))
  };
}

function financeSurface(overrides = {}) {
  return {
    version: 2,
    type: "finance",
    title: "Example quote",
    asset: { name: "Example Corp", ticker: "EX" },
    quote: {
      price: "$10.00",
      afterHours: {
        price: "$10.20",
        change: "+$0.20",
        changePercent: "+2.00%",
        label: "After hours",
        trend: "up"
      }
    },
    selectedRange: "1D",
    series: [financeSeries("1D"), financeSeries("1W")],
    metrics: [{ label: "Volume", value: "1.2M" }],
    ...overrides
  };
}

function currencySurface(overrides = {}) {
  return {
    version: 2,
    type: "currency",
    title: "USD to CNY",
    from: { code: "USD", name: "US Dollar", symbol: "$", flag: "🇺🇸" },
    to: { code: "CNY", name: "Renminbi", symbol: "¥", flag: "🇨🇳" },
    amount: 1,
    rate: 7.2,
    fractionDigits: 2,
    ...overrides
  };
}

test("strict v2 renders distinct news and web-results DOM without generic-link pollution", () => {
  const news = rich(resultSurface("news", {
    state: "partial",
    message: "Coverage is still updating.",
    source: "Captured search result group",
    sourceUrl: "https://example.com/source",
    asOf: "2026-08-28 12:00 UTC"
  }));
  const web = rich(resultSurface("web_results"));

  assert.match(news, /class="scopy-rich scopy-rich-news"/);
  assert.match(news, /id="scopy-rich-news-0"/);
  assert.match(news, /data-type="news" data-state="partial" data-scopy-version="2"/);
  assert.match(news, /class="scopy-rich-news-track(?: scopy-rich-news-track--wide)?"/);
  assert.match(news, /class="scopy-rich-news-link" aria-label="A story"/);
  assert.match(news, /src="rich\/news-openai-hugging-face.jpg"/);
  assert.match(news, /src="rich\/favicon-openai-32.png"/);
  assert.match(news, /Coverage is still updating/);
  assert.doesNotMatch(news, /scopy-link--external|scopy-icon--external-link/);

  assert.match(web, /class="scopy-rich scopy-rich-web-results"/);
  assert.match(web, /id="scopy-rich-web_results-0-item-0"/);
  assert.match(web, /class="scopy-rich-web-result-title"/);
  assert.match(web, /class="scopy-rich-web-result-link"/);
  assert.doesNotMatch(web, /scopy-link--external|scopy-icon--external-link/);
});

test("strict v2 image groups expose lightbox actions and never fetch remote images", () => {
  const html = rich({
    version: 2,
    type: "image_group",
    title: "Images",
    layout: "search",
    initialIndex: 1,
    images: [
      { src: DATA_IMAGE, alt: "Inline", title: "Inline title" },
      { asset: "image-group-chatgpt-search-results", alt: "Bundled", source: "ChatGPT" },
      { src: "https://example.com/remote.webp", alt: "Remote" }
    ]
  });

  assert.match(html, /class="scopy-rich-image-grid scopy-rich-image-layout-search"/);
  assert.doesNotMatch(html, /scopy-rich-image-count-/);
  assert.match(html, /data-scopy-interactive="true" data-scopy-lightbox-index="1"/);
  assert.match(html, /data-scopy-action="lightbox-open" data-scopy-index="0"/);
  assert.match(html, /data-scopy-action="lightbox-close"/);
  assert.match(html, /<img src="data:image\/png;base64,aGVsbG8=" alt="Inline" class="scopy-rich-image">/);
  assert.match(html, /<img src="rich\/image-group-chatgpt-search-results.jpg" alt="Bundled" class="scopy-rich-image">/);
  assert.match(html, /Remote image unavailable offline: Remote/);
  assert.doesNotMatch(html, /<img[^>]+https:\/\/example.com\/remote.webp/);
  assert.doesNotMatch(html, /data-scopy-trusted-image/);
});

test("strict v2 weather renders both frozen units and interactive day controls", () => {
  const html = rich(weatherSurface());

  assert.match(html, /data-scopy-interactive="true" data-scopy-unit="C" data-scopy-day-index="0"/);
  assert.match(html, /data-scopy-action="weather-unit" data-scopy-unit="F"/);
  assert.match(html, /data-scopy-action="weather-unit" data-scopy-unit="C"/);
  assert.match(html, /data-scopy-action="weather-day" data-scopy-index="0"/);
  assert.match(html, /data-scopy-weather-panel="1" data-scopy-index="1" hidden/);
  assert.match(html, /data-scopy-unit-value="F" hidden class="scopy-rich-ltr">77°F/);
  assert.match(html, /data-scopy-unit-value="C" class="scopy-rich-ltr">25°C/);
  assert.match(html, /src="rich\/weather-mostly-cloudy-light.png"/);
});

test("strict v2 finance renders precomputed ranges, SVG charts, and probe metadata", () => {
  const html = rich(financeSurface());

  assert.match(html, /class="scopy-rich-finance-asset">Example Corp<span class="scopy-rich-ltr"> \(EX\)<\/span>/);
  assert.match(html, /class="scopy-rich-finance-price">\$10\.00<\/p>/);
  assert.match(html, /class="scopy-rich-finance-after-hours-price">\$10\.20<\/span>/);
  assert.match(html, /data-scopy-interactive="true" data-scopy-range-index="0"/);
  assert.match(html, /data-scopy-action="finance-range" data-scopy-index="1"/);
  assert.match(html, /data-scopy-finance-panel="1" data-scopy-index="1" hidden/);
  assert.match(html, /data-scopy-action="chart-probe" data-scopy-chart-count="2" tabindex="0" role="img"/);
  assert.match(html, /data-scopy-chart-point="true" data-scopy-index="0"/);
  assert.match(html, /data-scopy-display="\$9\.00"/);
  assert.match(html, /<svg viewBox="0 0 738 240" aria-hidden="true" focusable="false">/);
  assert.match(html, /<linearGradient[^>]+x1="0%" x2="0%" y1="0%" y2="100%" gradientUnits="objectBoundingBox">/);
  assert.match(html, /<stop offset="0%" stop-color="currentColor" stop-opacity="0\.24"><\/stop>/);
  assert.match(html, /<stop offset="100%" stop-color="currentColor" stop-opacity="0"><\/stop>/);
  assert.doesNotMatch(html, /stop-color="#/);
  assert.match(html, /<dt>Volume<\/dt><dd>1\.2M<\/dd>/);
});

test("strict v2 currency is numeric, bidirectional, and leaves its inputs enabled", () => {
  const html = rich(currencySurface());

  assert.match(html, /data-scopy-interactive="true" data-scopy-rate="7\.2" data-scopy-fraction-digits="2"/);
  assert.match(html, /id="scopy-rich-currency-0-currency-from"[^>]+data-scopy-action="currency-input" data-scopy-currency-side="from" value="1"/);
  assert.match(html, /id="scopy-rich-currency-0-currency-to"[^>]+data-scopy-action="currency-input" data-scopy-currency-side="to" value="7\.20"/);
  assert.doesNotMatch(html, /<input[^>]+disabled/);
  assert.doesNotMatch(html, /<dt>Rate|<dt>Result/);
});

test("the bundled image asset map is closed and every mapped file is real", () => {
  const html = rich({
    version: 2,
    type: "image_group",
    layout: "carousel",
    images: Object.keys(BUNDLED_IMAGE_ASSETS).map((asset) => ({ asset, alt: asset }))
  });

  for (const [asset, relativePath] of Object.entries(BUNDLED_IMAGE_ASSETS)) {
    assert.equal(existsSync(previewAssetRoot + relativePath), true, `${asset} file exists`);
    assert.match(html, new RegExp(`src="${relativePath.replaceAll(".", "\\.")}"`));
  }
  assert.match(rich({
    version: 2,
    type: "image_group",
    layout: "carousel",
    images: [{ asset: "rich/arbitrary-user-file.png", alt: "bad" }]
  }), CODE_FENCE);
});

test("v1, unknown keys, invalid values, oversized blocks, and deep objects stay code", () => {
  const invalidValues = [
    { version: 1, type: "currency", from: { code: "USD" }, to: { code: "EUR" }, amount: 1, rate: 1, fractionDigits: 2 },
    { ...currencySurface(), result: "legacy field" },
    { ...currencySurface(), amount: "1.00 USD" },
    resultSurface("news", { items: [] }),
    resultSurface("news", { items: [{ title: "bad", url: "https://user:pass@example.com" }] }),
    { ...currencySurface(), from: { code: "X".repeat(4_097) } },
    { version: 2, type: "unknown", items: [] },
    { version: 2, type: "news", items: [], nested: { a: { b: { c: { d: { e: { f: { g: true } } } } } } } }
  ];
  for (const value of invalidValues) {
    const html = rich(value);
    assert.match(html, CODE_FENCE);
    assert.doesNotMatch(html, /<section class="scopy-rich/);
  }

  const oversized = `\`\`\`scopy-rich\n${"x".repeat(1_024 * 1_024 + 1)}\n\`\`\``;
  assert.match(render(oversized).html, CODE_FENCE);
});

test("strict v2 enforces result, image, weather, finance, and metric bounds", () => {
  const item = { title: "Story", url: "https://example.com/story" };
  assert.match(rich(resultSurface("news", { items: Array.from({ length: 20 }, () => item) })), /scopy-rich-news-track/);
  assert.match(rich(resultSurface("news", { items: Array.from({ length: 21 }, () => item) })), CODE_FENCE);

  const image = { src: "https://example.com/image.png", alt: "Image" };
  assert.match(rich({ version: 2, type: "image_group", layout: "carousel", images: Array.from({ length: 12 }, () => image) }), /scopy-rich-image-grid/);
  assert.match(rich({ version: 2, type: "image_group", layout: "carousel", images: Array.from({ length: 13 }, () => image) }), CODE_FENCE);

  const baseDay = weatherSurface().days[0];
  assert.match(rich(weatherSurface({ days: Array.from({ length: 10 }, () => baseDay), selectedDay: 9 })), /scopy-rich-weather-card/);
  assert.match(rich(weatherSurface({ days: Array.from({ length: 11 }, () => baseDay) })), CODE_FENCE);
  assert.match(rich(weatherSurface({ days: [{ ...baseDay, hourly: Array.from({ length: 25 }, () => baseDay.hourly[0]) }] })), CODE_FENCE);

  assert.match(rich(financeSurface({
    selectedRange: "R7",
    series: Array.from({ length: 8 }, (_, index) => financeSeries(`R${index}`, 2)),
    metrics: Array.from({ length: 16 }, () => ({ label: "P/E", value: "10x" }))
  })), /scopy-rich-finance-card/);
  assert.match(rich(financeSurface({
    selectedRange: "R0",
    series: Array.from({ length: 9 }, (_, index) => financeSeries(`R${index}`, 2))
  })), CODE_FENCE);
  assert.match(rich(financeSurface({ series: [financeSeries("1D", 257)] })), CODE_FENCE);
  assert.match(rich(financeSurface({ metrics: Array.from({ length: 17 }, () => ({ label: "P/E", value: "10x" })) })), CODE_FENCE);
  assert.match(rich(financeSurface({
    selectedRange: "R0",
    series: Array.from({ length: 8 }, (_, index) => financeSeries(`R${index}`, 129))
  })), CODE_FENCE);
});

test("strict v2 enforces URL and decoded data-image byte bounds", () => {
  const prefix = "https://example.com/";
  const atLimit = prefix + "a".repeat(2_048 - prefix.length);
  const overLimit = `${atLimit}a`;
  assert.match(rich(resultSurface("news", { items: [{ title: "At limit", url: atLimit }] })), /scopy-rich-news-track/);
  assert.match(rich(resultSurface("news", { items: [{ title: "Over", url: overLimit }] })), CODE_FENCE);

  const dataPrefix = "data:image/png;base64,";
  const payloadLength = Math.floor((256 * 1_024) / 3) * 4;
  assert.equal(isRenderableDataImage(dataPrefix + "A".repeat(payloadLength)), true);
  assert.equal(isRenderableDataImage(dataPrefix + "A".repeat(payloadLength + 4)), false);
  assert.equal(isRenderableDataImage("data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="), false);

  const dataImage = dataPrefix + "A".repeat(payloadLength);
  assert.match(rich({ version: 2, type: "image_group", layout: "carousel", images: [{ src: dataImage, alt: "one" }, { src: dataImage, alt: "two" }] }), /scopy-rich-image-grid/);
  assert.match(rich({ version: 2, type: "image_group", layout: "carousel", images: [{ src: dataImage, alt: "one" }, { src: dataImage, alt: "two" }, { src: "data:image/png;base64,AAAA", alt: "three" }] }), CODE_FENCE);
});

test("empty and error states require messages while partial retains a bounded body", () => {
  for (const state of ["empty", "error"]) {
    const html = rich({ version: 2, type: "news", state, title: "News", message: `${state} message` });
    assert.match(html, new RegExp(`data-state="${state}"`));
    assert.match(html, new RegExp(`${state} message`));
    assert.doesNotMatch(html, /scopy-rich-news-track/);
  }
  assert.match(rich({ version: 2, type: "news", state: "error" }), CODE_FENCE);
  assert.match(rich({ version: 2, type: "news", state: "empty", message: "none", items: [] }), CODE_FENCE);
  assert.match(rich(resultSurface("news", { state: "partial", message: "One result unavailable" })), /One result unavailable/);
});

test("adjacent ordinary images use the v2 image-group path while one image stays ordinary", () => {
  const grouped = render("![one](https://example.com/one.png)\n\n![two](data:image/png;base64,aGVsbG8=)").html;
  const single = render("![one](https://example.com/one.png)").html;
  const separated = render("![one](https://example.com/one.png)\n\nText\n\n![two](https://example.com/two.png)").html;

  assert.match(grouped, /class="scopy-rich scopy-rich-image-group"/);
  assert.match(grouped, /data-scopy-version="2"/);
  assert.match(grouped, /id="scopy-rich-image_group-0"/);
  assert.match(grouped, /aria-label="Image group with 2 images"/);
  assert.doesNotMatch(grouped, /<img[^>]+https:\/\/example.com\/one.png/);
  assert.match(single, /^<p><img src="https:\/\/example.com\/one.png" alt="one"><\/p>$/);
  assert.doesNotMatch(single, /scopy-rich-image-group/);
  assert.doesNotMatch(separated, /scopy-rich-image-group/);
});

test("only the two verified public-copy image URLs resolve to bundled assets", () => {
  const sourcesURL = "https://images.ctfassets.net/kftzwdyauwt9/1lzvjTVvojn23RPUeYr51u/9e11ca889ec10a05e5601919b98c54d2/Sources_Sidebar.png?fm=webp&q=90&w=3840";
  const entryURL = "https://images.ctfassets.net/kftzwdyauwt9/7LzxdzMcijUYHtIES6rmub/1dd3bc9f423a6b1cd5176936dbb029aa/Entry_Point.png?fm=webp&q=90&w=3840";

  assert.equal(bundledImageAssetForExactRemoteURL(sourcesURL), "image-group-chatgpt-search-results");
  assert.equal(bundledImageAssetForExactRemoteURL(entryURL), "image-group-chatgpt-search-button");
  assert.equal(bundledImageAssetForExactRemoteURL(sourcesURL.replace("w=3840", "w=2048")), null);
  assert.equal(bundledImageAssetForExactRemoteURL("https://example.com/unknown.png"), null);

  const html = render(`![Sources sidebar](${sourcesURL})\n\n![Entry point](${entryURL})`).html;
  assert.equal((html.match(/class="scopy-rich scopy-rich-image-group"/g) || []).length, 1);
  assert.match(html, /<img src="rich\/image-group-chatgpt-search-results\.jpg" alt="Sources sidebar" class="scopy-rich-image">/);
  assert.match(html, /<img src="rich\/image-group-chatgpt-search-button\.jpg" alt="Entry point" class="scopy-rich-image">/);
  assert.doesNotMatch(html, /<img[^>]+src="https?:\/\//i);

  const unknown = render("![near miss](https://images.ctfassets.net/kftzwdyauwt9/1lzvjTVvojn23RPUeYr51u/9e11ca889ec10a05e5601919b98c54d2/Sources_Sidebar.png?fm=webp&q=90&w=2048)\n\n![unknown](https://example.com/unknown.png)").html;
  assert.equal((unknown.match(/class="scopy-rich-image-placeholder scopy-rich-image"/g) || []).length, 2);
  assert.doesNotMatch(unknown, /src="rich\/image-group-chatgpt-search-results\.jpg"/);
  assert.doesNotMatch(unknown, /<img[^>]+src="https?:\/\//i);
});

test("rich IDs are stable zero-based AST ordinals and invalid fences retain slots", () => {
  const first = JSON.stringify(currencySurface());
  const second = JSON.stringify(financeSurface());
  const html = render(`\`\`\`scopy-rich\n{}\n\`\`\`\n\n\`\`\`scopy-rich\n${first}\n\`\`\`\n\n![a](https://example.com/a.png)\n\n![b](https://example.com/b.png)\n\n\`\`\`scopy-rich\n${second}\n\`\`\``).html;

  assert.match(html, CODE_FENCE);
  assert.match(html, /id="scopy-rich-currency-1"/);
  assert.match(html, /id="scopy-rich-image_group-2"/);
  assert.match(html, /id="scopy-rich-image_group-2-image-0"/);
  assert.match(html, /id="scopy-rich-finance-3"/);
  assert.doesNotMatch(html, /[a-f0-9]{32,}/);
});

test("raw HTML remains literal beside trusted v2 HAST and fence meta stays code", () => {
  const value = JSON.stringify(currencySurface());
  const html = render(`<script>alert(1)</script>\n\n\`\`\`scopy-rich\n${value}\n\`\`\``).html;
  const meta = render(`\`\`\`scopy-rich preview\n${value}\n\`\`\``).html;

  assert.match(html, /&#x3C;script>alert\(1\)&#x3C;\/script>/);
  assert.doesNotMatch(html, /<script(?:\s|>)/i);
  assert.match(html, /class="scopy-rich scopy-rich-currency"/);
  assert.match(meta, CODE_FENCE);
  assert.doesNotMatch(meta, /class="scopy-rich scopy-rich-currency"/);
});
