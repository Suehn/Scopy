import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";

test("renders GFM links, tables, task lists, and dollar math", () => {
  const result = render(`
# Title

- [x] done
- [doc](/Users/alice/project/file.md:25)

| a | b |
| --- | --- |
| $x_1$ | 2 |
`);

  assert.equal(result.metadata.renderer, "unified");
  assert.match(result.html, /<h1>Title<\/h1>/);
  assert.match(result.html, /class="contains-task-list"/);
  assert.match(result.html, /href="\/Users\/alice\/project\/file.md:25"/);
  assert.match(result.html, /<table>/);
  assert.match(result.html, /katex/);
});

test("does not allow raw HTML in the first bundle", () => {
  const result = render("<script>alert(1)</script>\n\n<details><summary>x</summary>y</details>");

  assert.doesNotMatch(result.html, /<script>/);
  assert.doesNotMatch(result.html, /<details>/);
});

test("renders backslash inline and display math", () => {
  const result = render("Inline \\(x_1 + y\\)\n\n\\[\\int_0^1 x dx\\]");

  assert.equal(result.metadata.warnings.length, 0);
  assert.equal(result.metadata.mathCount, 2);
  assert.match(result.html, /katex/);
  assert.match(result.html, /katex-display/);
  assert.doesNotMatch(result.html, /\\\(x_1 \+ y\\\)/);
});

test("does not rewrite backslash math inside code or links", () => {
  const result = render("`\\(code\\)` [\\(label\\)](/tmp/\\(path\\).md)\n\nReal \\(x\\)");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /<code>\\\(code\\\)<\/code>/);
  assert.match(result.html, /href="\/tmp\/\(path\).md"/);
  assert.match(result.html, />\(label\)<\/a>/);
  assert.match(result.html, /katex/);
});
