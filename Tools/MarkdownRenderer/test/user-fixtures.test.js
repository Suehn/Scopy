import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { render } from "../src/render.js";

const fixtureRoot = new URL("../../../ScopyUITests/Fixtures/", import.meta.url);

test("renders the full user Markdown stress fixture without structural corruption", () => {
  const source = readFileSync(new URL("user_markdown_stress.md", fixtureRoot), "utf8");
  const result = render(source);

  assert.ok(result.html.length > source.length);
  assert.ok(result.metadata.mathCount >= 100);
  assert.match(result.html, /<h1[^>]*>/);
  assert.match(result.html, /<table>/);
  assert.match(result.html, /<pre><code/);
  assert.match(result.html, /class="katex/);
  assert.doesNotMatch(result.html, /<script/i);
  assert.doesNotMatch(result.html, /scopy-render-error/);
});

test("renders copied ChatGPT rich-surface prose as stable ordinary Markdown", () => {
  const source = readFileSync(new URL("chatgpt_rich_copy_sample.md", fixtureRoot), "utf8");
  const result = render(source);

  assert.ok(result.html.length > source.length);
  assert.doesNotMatch(result.html, /class="scopy-rich(?:\s|\")/);
  assert.doesNotMatch(result.html, /href="https:\/\/\.\.\.[^"]*" class="scopy-link scopy-link--external"/);
  assert.doesNotMatch(result.html, /<script/i);
  assert.doesNotMatch(result.html, /scopy-render-error/);
});
