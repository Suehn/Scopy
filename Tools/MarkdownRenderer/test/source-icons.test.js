import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { render } from "../src/render.js";
import { BUNDLED_IMAGE_ASSETS, bundledFaviconAssetForHost } from "../src/scopyLocalImageAssets.js";

const fixture = new URL("../../../ScopyUITests/Fixtures/markdown_link_icons.md", import.meta.url);
const png = "data:image/png;base64," + readFileSync(new URL("../../../ScopyUITests/Fixtures/Assets/chatgpt-rich/favicon-hsbc-hk-32.png", import.meta.url)).toString("base64");

test("bank links, citations and news/search sources share exact-host branded artwork offline", () => {
  const { html } = render(readFileSync(fixture, "utf8"));
  assert.match(html, /class="scopy-link scopy-link--external"><img src="rich\/favicon-elebank-150.png"[^>]*><span class="scopy-link__label">大象官方说明/);
  assert.match(html, /class="scopy-link scopy-link--external"><img src="rich\/favicon-hsbc-hk-32.png"[^>]*><span class="scopy-link__label">汇丰 FPS 常见问题/);
  assert.match(html, /favicon-hsbc-hk-32.png"[^>]+scopy-source-citation-origin-icon/);
  assert.match(html, /favicon-hsbc-hk-32.png"[^>]+scopy-rich-origin-icon/);
  assert.match(html, /favicon-elebank-150.png"[^>]+scopy-rich-origin-icon/);
  assert.doesNotMatch(html, /scopy-icon--external-link|<img[^>]+src="https?:/);
  for (const name of ["favicon-elebank-150", "favicon-hsbc-hk-32"]) {
    const file = BUNDLED_IMAGE_ASSETS[name].split("/").at(-1);
    assert.deepEqual(readFileSync(new URL(`../../../Scopy/Resources/MarkdownPreview/rich/${file}`, import.meta.url)), readFileSync(new URL(`../../../ScopyUITests/Fixtures/Assets/chatgpt-rich/${file}`, import.meta.url)));
  }
});

test("labels and lookalike hosts cannot select bank branding", () => {
  for (const host of ["hsbc.com.hk.evil.example", "fake.hsbc.com.hk", "elebank.com.evil.example", "evil-elebank.com"]) {
    assert.equal(bundledFaviconAssetForHost(host), null);
    const { html } = render(`[大象银行 汇丰](https://${host}/)`);
    assert.match(html, /scopy-icon--globe scopy-link-origin-icon/);
    assert.doesNotMatch(html, /<img/);
  }
  assert.match(render("[汇丰](https://WWW.HSBC.COM.HK/path)").html, /favicon-hsbc-hk-32/);
  for (const url of ["https://user:pass@www.hsbc.com.hk", "https://www.hsbc.com.hk/%0a", "javascript:alert(1)"]) {
    assert.doesNotMatch(render(`[汇丰](${url})`).html, /scopy-link-origin-icon|favicon-hsbc/);
  }
});

test("descriptive ordinary links reuse only bounded frozen raster favicons and keep their label", () => {
  const url = "https://example.com/details";
  const policy = { linkEnrichment: { [url]: { title: "Different fetched title", favicon: png } } };
  const { html } = render(`正文 [详细步骤](${url})`, policy);
  assert.match(html, /scopy-link-origin-icon/);
  assert.ok(html.includes(png));
  assert.match(html, /<span class="scopy-link__label">详细步骤<\/span>/);
  assert.doesNotMatch(html, /scopy-rich-news|Different fetched title/);
  for (const favicon of ["https://example.com/icon.png", "data:image/svg+xml;base64,PHN2Zz4=", "data:image/png;base64," + "A".repeat(400000)]) {
    assert.match(render(`正文 [步骤](${url})`, { linkEnrichment: { [url]: { favicon } } }).html, /scopy-icon--globe scopy-link-origin-icon/);
  }
});

test("linked images, local files, plugins, tasks and footnotes keep their own icon semantics", () => {
  assert.doesNotMatch(render("[![logo](https://example.com/logo.png)](https://www.hsbc.com.hk)").html, /scopy-link-origin-icon|scopy-icon--external-link/);
  assert.match(render("[![logo](https://example.com/logo.png) 官网](https://www.hsbc.com.hk)").html, /favicon-hsbc-hk/);
  const { html } = render(readFileSync(fixture, "utf8"));
  for (const kind of ["file-text", "javascript-badge", "code", "image", "puzzle-piece"]) assert.ok(html.includes(`scopy-icon--${kind}`), kind);
  assert.match(html, /scopy-link--plugin" aria-disabled="true"><svg/);
  assert.match(html, /type="checkbox" checked disabled/);
  assert.match(html, /data-footnote-ref/);
  assert.doesNotMatch(html, /data-footnote-ref[^>]*><(?:img|svg)/);
});

test("repeated frozen favicons have an aggregate emitted budget", () => {
  const url = "https://example.com/repeat";
  const favicon = "data:image/png;base64," + "A".repeat(262144);
  const { html } = render(Array(25).fill(`[步骤](${url})`).join(" "), { linkEnrichment: { [url]: { favicon } } });
  assert.ok(html.length < 600000);
  assert.equal((html.match(/data:image\/png;base64/g) || []).length, 1);
  assert.equal((html.match(/scopy-icon--globe/g) || []).length, 24);
});
