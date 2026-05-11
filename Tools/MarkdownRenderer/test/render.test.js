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
