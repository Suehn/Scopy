import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";

const rich = (value) => "```scopy-rich\n" + JSON.stringify(value) + "\n```";
const CODE_FENCE = /<pre><code class="(?:hljs )?language-scopy-rich">/;

test("strict v2 video, product, entity, and map envelopes render dedicated cards", () => {
  const video = render(rich({
    version: 2, type: "video", state: "ready",
    title: "Demo", channel: "OpenAI", duration: "18:32",
    url: "https://www.youtube.com/watch?v=abc"
  })).html;
  assert.match(video, /scopy-rich scopy-rich-video/);
  assert.match(video, /scopy-rich-video-play/);
  assert.match(video, /scopy-rich-video-meta">OpenAI · 18:32</);

  const entity = render(rich({
    version: 2, type: "entity", state: "ready",
    name: "Blue Bottle Coffee", url: "https://bluebottlecoffee.com",
    category: "Coffee shop", rating: 4.5, ratingCount: "1,214", priceLevel: "$$",
    address: "315 Linden St", phone: "+1 510-661-3510"
  })).html;
  assert.match(entity, /scopy-rich-entity-name/);
  assert.match(entity, /data-scopy-rating-halves="9"/);
  assert.match(entity, /scopy-rich-entity-detail-label">Phone</);

  const map = render(rich({
    version: 2, type: "map", state: "ready",
    image: { asset: "image-group-chatgpt-search-results", alt: "Static map" },
    pins: [{ label: "A", detail: "1st St" }, { label: "B" }]
  })).html;
  assert.match(map, /scopy-rich-map-frame/);
  assert.equal((map.match(/scopy-rich-map-pin"/g) || []).length, 2);
});

test("invalid new-type envelopes stay literal code fences", () => {
  const cases = [
    { version: 2, type: "video", state: "ready", title: "No URL" },
    { version: 2, type: "video", state: "ready", title: "Bad", url: "file:///tmp/x" },
    { version: 2, type: "product", state: "ready", product: { url: "https://a.example" } },
    { version: 2, type: "product", state: "ready", product: { title: "X", rating: 5.2 } },
    { version: 2, type: "product_carousel", state: "ready", items: [{ title: "only one" }] },
    { version: 2, type: "entity", state: "ready", name: "X", priceLevel: "$$$$$" },
    { version: 2, type: "map", state: "ready", pins: [{ label: "no image" }] },
    { version: 2, type: "map", state: "ready", image: { asset: "unknown-asset" } }
  ];
  for (const value of cases) {
    const html = render(rich(value)).html;
    assert.match(html, CODE_FENCE, JSON.stringify(value));
    assert.doesNotMatch(html, /class="scopy-rich /, JSON.stringify(value));
  }
});

test("public-copy adapters promote only the exact video, product, and place shapes", () => {
  const source = [
    "[OpenAI — Search: 12 Days of OpenAI, Day 8](https://www.youtube.com/watch?v=lRRoz44Njjs)",
    "",
    "### [Logitech MX Master 3S](https://www.walmart.com/ip/731473988)",
    "",
    "*$79.99*",
    "",
    "Blue Bottle Coffee",
    "",
    "Blue Bottle Coffee\\",
    "[Web](https://bluebottlecoffee.com)\\",
    "Address: 315 Linden St, San Francisco, CA 94102, United States\\",
    "Phone: +1 510-661-3510",
    ""
  ].join("\n");
  const html = render(source).html;

  assert.match(html, /scopy-rich-video-title">OpenAI — Search: 12 Days of OpenAI, Day 8</);
  assert.match(html, /scopy-rich-product-title">Logitech MX Master 3S</);
  assert.match(html, /scopy-rich-product-price">\$79\.99</);
  assert.match(html, /scopy-rich-entity-name[^>]*>Blue Bottle Coffee</);
  assert.match(html, /scopy-rich-entity-detail-label">Address</);
  assert.doesNotMatch(html, />Blue Bottle Coffee<\/p>/, "the duplicate bare-name paragraph folds into the card");
});

test("near-miss shapes stay ordinary prose instead of becoming guessed cards", () => {
  const html = render([
    "[Ordinary article](https://example.com/story)",
    "",
    "Some ordinary paragraph, not a price.",
    "",
    "[Video plus trailing prose](https://www.youtube.com/watch?v=abc) trailing words",
    "",
    "Blue Bottle Coffee\\",
    "[Web](https://bluebottlecoffee.com)\\",
    "Phone: +1 510-661-3510",
    ""
  ].join("\n")).html;

  assert.doesNotMatch(html, /scopy-rich-video|scopy-rich-product|scopy-rich-entity/);
  assert.match(html, /scopy-link--external/);
});

test("adapter output and fenced envelopes share one ordinal namespace", () => {
  const html = render([
    "[Clip](https://youtu.be/abc)",
    "",
    "```scopy-rich",
    JSON.stringify({ version: 2, type: "entity", state: "ready", name: "Place", address: "1 Main St" }),
    "```",
    ""
  ].join("\n")).html;
  assert.match(html, /id="scopy-rich-video-0"/);
  assert.match(html, /id="scopy-rich-entity-1"/);
});

test("frozen link enrichment upgrades bare-link runs through the v2 validators", () => {
  const source = "- [OpenAI](https://openai.com/index/a/)\n- [OpenAI](https://openai.com/index/b/)\n\n[Solo](https://example.com/story)\n";
  const enrichment = {
    "https://openai.com/index/a/": { title: "Article A", source: "OpenAI", date: "Yesterday" },
    "https://openai.com/index/b/": { title: "Article B", source: "OpenAI", image: "data:image/png;base64,aGVsbG8=" },
    "https://example.com/story": { title: "Solo article", source: "example.com", snippet: "Short." }
  };
  const enriched = render(source, { linkEnrichment: enrichment }).html;
  assert.deepEqual(
    Array.from(enriched.matchAll(/data-type="([^"]+)"/g), (m) => m[1]),
    ["news", "web_results"]
  );
  assert.match(enriched, /scopy-rich-news-title">Article A</);
  assert.match(enriched, /Solo article/);

  const plain = render(source).html;
  assert.doesNotMatch(plain, /class="scopy-rich /);
  assert.match(plain, /scopy-link--external/);

  const partial = render(source, {
    linkEnrichment: { "https://openai.com/index/a/": { title: "Only A" } }
  }).html;
  assert.doesNotMatch(partial, /data-type="news"/, "a run promotes only when every link is enriched");
});
