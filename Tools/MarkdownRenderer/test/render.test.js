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

test("preserves safe HTML subset but still removes unsafe raw HTML", () => {
  const result = render("<script>alert(1)</script>\n\n<details><summary>x</summary>y</details>");

  assert.doesNotMatch(result.html, /<script>/);
  assert.match(result.html, /<details class="scopy-details">/);
  assert.match(result.html, /<summary>x<\/summary>/);
  assert.match(result.html, /<p>y<\/p>/);
});

test("renders backslash inline and display math", () => {
  const result = render("Inline \\(x_1 + y\\)\n\n\\[\\int_0^1 x dx\\]");

  assert.equal(result.metadata.warnings.length, 0);
  assert.equal(result.metadata.mathCount, 2);
  assert.match(result.html, /katex/);
  assert.match(result.html, /katex-display/);
  assert.doesNotMatch(result.html, /\\\(x_1 \+ y\\\)/);
});

test("renders multiline backslash display math", () => {
  const result = render("\\[\n\\int_0^1 x dx\n\\]");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /katex-display/);
  assert.doesNotMatch(result.html, /\[<br>/);
});

test("does not rewrite backslash math inside code or links", () => {
  const result = render("`\\(code\\)` [\\(label\\)](/tmp/\\(path\\).md)\n\nReal \\(x\\)");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /<code>\\\(code\\\)<\/code>/);
  assert.match(result.html, /href="\/tmp\/\(path\).md"/);
  assert.match(result.html, />\(label\)<\/a>/);
  assert.match(result.html, /katex/);
});

test("renders safe inline HTML and does not rewrite fenced raw HTML", () => {
  const result = render("Text <kbd>Cmd</kbd> and <mark>hot</mark>\n\n```\n<kbd>code</kbd>\n```");

  assert.match(result.html, /Text <kbd>Cmd<\/kbd> and <mark>hot<\/mark>/);
  assert.match(result.html, /<code>&#x3C;kbd>code&#x3C;\/kbd>/);
});

test("can disable safe HTML subset", () => {
  const result = render("<details><summary>x</summary>y</details>", { allowSafeHTMLSubset: false });

  assert.doesNotMatch(result.html, /<details/);
  assert.doesNotMatch(result.html, /<summary/);
});

test("repairs loose math only when policy allows it", () => {
  const source = "The set (\\mathcal{U}) stays readable.";
  const disabled = render(source, { allowLooseMathRepair: false });
  const enabled = render(source, { allowLooseMathRepair: true });

  assert.equal(disabled.metadata.repairedMathCount, 0);
  assert.doesNotMatch(disabled.html, /katex/);
  assert.equal(enabled.metadata.repairedMathCount, 1);
  assert.match(enabled.html, /katex/);
});

test("loose repair skips parsed markdown syntax islands", () => {
  const result = render(
    "[\\mathcal{L}](/tmp/file_1.md) `\\mathcal{C}`\n\n| col |\n| --- |\n| (\\mathcal{T}) |\n\nOutside (\\mathcal{S})",
    { allowLooseMathRepair: true }
  );

  assert.equal(result.metadata.repairedMathCount, 1);
  assert.match(result.html, /href="\/tmp\/file_1.md"/);
  assert.match(result.html, /<code>\\mathcal\{C\}<\/code>/);
  assert.match(result.html, /\\mathcal\{T\}/);
  assert.match(result.html, /katex/);
});

test("loose repair rejects paths urls and currency", () => {
  const result = render(
    "Path (/Users/alice/project/file_v2.md:25), url (https://example.com/a_b?q=1), price ($20).",
    { allowLooseMathRepair: true }
  );

  assert.equal(result.metadata.repairedMathCount, 0);
  assert.doesNotMatch(result.html, /katex/);
  assert.match(result.html, /\/Users\/alice\/project\/file_v2.md:25/);
  assert.match(result.html, /https:\/\/example.com\/a_b\?q=1/);
  assert.match(result.html, /\$20/);
});

test("does not parse currency or shell variables as dollar math", () => {
  const result = render("The price is $20 and price=$20. Use $HOME/bin outside code too.");

  assert.equal(result.metadata.mathCount, 0);
  assert.doesNotMatch(result.html, /katex/);
  assert.match(result.html, /\$20/);
  assert.match(result.html, /price=\$20/);
  assert.match(result.html, /\$HOME\/bin/);
});
