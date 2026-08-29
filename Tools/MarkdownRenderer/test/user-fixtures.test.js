import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { render } from "../src/render.js";

const fixtureRoot = new URL("../../../ScopyUITests/Fixtures/", import.meta.url);

test("renders the full user Markdown stress fixture without structural corruption", () => {
  const source = readFileSync(new URL("user_markdown_stress.md", fixtureRoot), "utf8");
  const result = render(source);

  assert.ok(result.html.length > source.length);
  assert.equal(result.metadata.mathCount, 132);
  assert.equal(result.metadata.mathStrictCount, 131);
  assert.equal(result.metadata.mathRelaxedCount, 1);
  assert.equal(result.metadata.mathErrorCount, 0);
  assert.match(result.html, /<h1[^>]*>/);
  assert.match(result.html, /<table>/);
  assert.match(result.html, /<pre><code/);
  assert.match(result.html, /class="katex/);
  assert.doesNotMatch(result.html, /<script/i);
  assert.doesNotMatch(result.html, /scopy-render-error/);
});

test("renders copied ChatGPT rich-surface prose as stable ordinary Markdown", () => {
  const fixtureURL = new URL("chatgpt_rich_copy_sample.md", fixtureRoot);
  const sourceBytes = readFileSync(fixtureURL);
  const source = sourceBytes.toString("utf8");
  const result = render(source);

  assert.equal(sourceBytes.length, 13_327);
  assert.equal(
    createHash("sha256").update(sourceBytes).digest("hex"),
    "0d853735388796c24d799e59cbe74662e7c52a30447668afa34d95b1b4a6a297"
  );
  assert.notEqual(sourceBytes.at(-1), 0x0a, "exact fixture must not gain a trailing LF");
  assert.notEqual(sourceBytes.at(-1), 0x0d, "exact fixture must not gain a trailing CR");

  assert.ok(result.html.length > source.length);
  assert.equal(result.metadata.mathCount, 0);
  assert.equal(result.metadata.mathStrictCount, 0);
  assert.equal(result.metadata.mathRelaxedCount, 0);
  assert.equal(result.metadata.mathErrorCount, 0);
  assert.deepEqual(result.metadata.warnings, []);
  assert.equal(countMatches(result.html, /class="scopy-source-citation-link"/g), 0);
  assert.equal(countMatches(result.html, /<img(?:\s|>)/g), 0);
  assert.doesNotMatch(result.html, /class="scopy-rich(?:\s|\")/);
  assert.doesNotMatch(result.html, /href="https:\/\/\.\.\.[^"]*" class="scopy-link scopy-link--external"/);
  assert.doesNotMatch(result.html, /<script/i);
  assert.doesNotMatch(result.html, /scopy-render-error/);
});

test("renders the complete strict-v2 rich fixture with its rejection example intact", () => {
  const source = readFileSync(new URL("chatgpt_rich_surfaces.md", fixtureRoot), "utf8");
  const result = render(source);

  assert.deepEqual(result.metadata.warnings, []);
  assert.deepEqual(
    Array.from(
      result.html.matchAll(/data-type="([^"]+)" data-state="([^"]+)" data-scopy-version="2"/g),
      (match) => [match[1], match[2]]
    ),
    [
      ["news", "ready"],
      ["image_group", "ready"],
      ["finance", "ready"],
      ["weather", "ready"],
      ["currency", "ready"],
      ["web_results", "ready"],
      ["video", "ready"],
      ["product", "ready"],
      ["product_carousel", "ready"],
      ["entity", "ready"],
      ["map", "ready"],
      ["news", "empty"]
    ]
  );
  assert.match(result.html, /scopy-rich-video-play/);
  assert.match(result.html, /scopy-rich-product-original-price">\$99\.99</);
  assert.equal(countMatches(result.html, /scopy-rich-product-card--carousel/g), 3);
  assert.match(result.html, /data-scopy-rating-halves="9"/);
  assert.match(result.html, /scopy-rich-entity-detail-label">Hours</);
  assert.equal(countMatches(result.html, /scopy-rich-map-pin"/g), 3);
  assert.match(result.html, /scopy-rich-map-image/);
  assert.equal(countMatches(result.html, /class="scopy-source-citation-link"/g), 1);
  assert.equal(countMatches(result.html, /<pre>/g), 1);
  assert.match(result.html, /<pre><code class="language-text">```scopy-rich\n\{"version":3,"type":"news","items":\[\]\}/);
  assert.match(result.html, /```scopy-rich preview\n\{"version":2,"type":"currency"/);
  assert.doesNotMatch(result.html, /<img[^>]+src="https?:\/\//i);
  assert.doesNotMatch(result.html, /<script(?:\s|>)/i);
  assert.doesNotMatch(result.html, /scopy-render-error/);
});

test("renders the exact public ChatGPT Markdown copy without reconstructing private cards", () => {
  const fixtureURL = new URL("chatgpt_public_copy_markdown_sample.md", fixtureRoot);
  const sourceBytes = readFileSync(fixtureURL);
  const source = sourceBytes.toString("utf8");
  const result = render(source);

  assert.equal(sourceBytes.length, 19_825);
  assert.equal(
    createHash("sha256").update(sourceBytes).digest("hex"),
    "724b6390b66698fc892e879b81297aac366dda5516bbfcb2f5dd3dd6108d087b"
  );
  assert.notEqual(sourceBytes.at(-1), 0x0a, "exact fixture must not gain a trailing LF");
  assert.notEqual(sourceBytes.at(-1), 0x0d, "exact fixture must not gain a trailing CR");

  assert.equal(result.metadata.mathCount, 3);
  assert.equal(result.metadata.mathStrictCount, 3);
  assert.equal(result.metadata.mathRelaxedCount, 0);
  assert.equal(result.metadata.mathErrorCount, 0);
  assert.deepEqual(result.metadata.warnings, []);
  assert.equal(countMatches(result.html, /<table>/g), 4);
  assert.equal(countMatches(result.html, /<pre>/g), 8);
  assert.equal(countMatches(result.html, /class="scopy-source-citation-link"/g), 20);
  assert.equal(countMatches(result.html, /class="scopy-rich scopy-rich-image-group"/g), 1);
  assert.equal(countMatches(result.html, /class="scopy-rich-image-placeholder scopy-rich-image"/g), 0);
  assert.equal(countMatches(result.html, /<img src="rich\/image-group-chatgpt-search-results\.jpg"/g), 1);
  assert.equal(countMatches(result.html, /<img src="rich\/image-group-chatgpt-search-button\.jpg"/g), 1);
  assert.ok(
    countMatches(result.html, /class="scopy-source-citation-origin-icon scopy-source-citation-favicon"/g) > 0,
    "mapped-host citations render bundled favicons"
  );
  assert.equal(
    countMatches(result.html, /<img[^>]*\ssrc="(?!rich\/)/g),
    0,
    "every image source is a bundled local asset"
  );

  assert.doesNotMatch(result.html, /<img[^>]+src="https?:\/\//i);
  // Field-preserving public adapters: the image group, one YouTube video, three copied
  // product blocks, and three copied place blocks become cards from visible fields only.
  assert.deepEqual(
    Array.from(result.html.matchAll(/class="scopy-rich scopy-rich-([^"\s]+)/g), (match) => match[1]),
    ["image-group", "video", "product", "product", "product", "entity", "entity", "entity"]
  );
  assert.match(result.html, /scopy-rich-video-title">OpenAI — Search: 12 Days of OpenAI, Day 8</);
  assert.deepEqual(
    Array.from(result.html.matchAll(/scopy-rich-product-title">([^<]+)</g), (match) => match[1]),
    ["Logitech MX Master 3S", "Keychron Q1 Max", "Sony WH-1000XM6"]
  );
  assert.deepEqual(
    Array.from(result.html.matchAll(/scopy-rich-product-price">([^<]+)</g), (match) => match[1]),
    ["$79.99", "$209.99", "$398.00"]
  );
  assert.deepEqual(
    Array.from(result.html.matchAll(/scopy-rich-entity-name[^>]*>([^<]+)</g), (match) => match[1]),
    ["Blue Bottle Coffee", "Sightglass Coffee", "Four Barrel Coffee"]
  );
  assert.match(result.html, /scopy-rich-entity-detail-label">Address</);
  assert.doesNotMatch(result.html, /scopy-rich-rating/, "no adapter invents ratings the copy does not carry");
  assert.match(
    result.html,
    /<a class="scopy-link scopy-link--inert">chatgpt_render_reference_demo\.txt<\/a>/
  );
  assert.doesNotMatch(result.html, /(?:href="[^"]*)?sandbox:/i);
  assert.doesNotMatch(result.html, /<script/i);
  assert.doesNotMatch(result.html, /scopy-render-error/);
});

function countMatches(value, pattern) {
  return (String(value).match(pattern) || []).length;
}
