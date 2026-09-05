import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { render } from "../src/render.js";

for (const [source, expected] of [
  ["这是**重点。**请注意", "这是<strong>重点。</strong>请注意"],
  ["请看**“重要结论”**并继续", "请看<strong>“重要结论”</strong>并继续"],
  ["这是**（关键条件）**需要满足", "这是<strong>（关键条件）</strong>需要满足"],
  ["中文*（斜体）*之后", "中文<em>（斜体）</em>之后"],
  ["中文**粗体里有*斜体*。**之后", "中文<strong>粗体里有<em>斜体</em>。</strong>之后"]
]) {
  test(`CJK delimiter boundaries: ${source}`, () => {
    assert.ok(render(source).html.includes(expected));
  });
}

for (const source of [
  "$x+1$", "$x_i+y_j$", "$NPV$", String.raw`$\frac{a}{b}$`,
  "中文$x$之后", "中文**$E=mc^2$**之后", "中文**$$E=mc^2$$**之后",
  String.raw`中文**\(E=mc^2\)**之后`, "[formula $x$](https://example.com)",
  "价格 $5，公式 $x+1$。"
]) {
  test(`inline math survives Markdown composition: ${source}`, () => {
    const result = render(source);
    assert.equal(result.metadata.mathCount, 1);
    assert.equal(result.metadata.mathErrorCount, 0);
    if (source.includes("**")) {
      assert.match(result.html, /<strong><span class="scopy-math-host/);
      assert.doesNotMatch(result.html, /\*\*/);
    }
    if (source.startsWith("价格")) assert.ok(result.html.includes("$5"));
  });
}

for (const source of [
  "价格 $5 和 $10。", "$5 and $10 and $20", "US$5 to US$10", "成本$5，售价$10。",
  "$50, $100。", "$19.99–$29.99", "$5\n$10", "$HOME/$PATH", "$HOME and $PATH",
  "/tmp/$x$/file", "https://example.com/$x$", "[price](https://example.com/$x$)",
  "`**粗体** $x$`", "```md\n**粗体** $x$\n```", "    **粗体** $x$",
  String.raw`\$x\$`, "$ x $", "$x $", "$ x$", "$x\ny$", "unclosed $x",
  "** 加粗 **", 'foo**"bar"**baz'
]) {
  test(`currency, syntax islands, or invalid delimiters stay literal: ${source}`, () => {
    const result = render(source);
    assert.equal(result.metadata.mathCount, 0);
    assert.doesNotMatch(result.html, /<strong>|class="katex/);
  });
}

test("separate single-dollar expressions do not merge across currency", () => {
  const result = render("$x$ costs $5; $y$ costs $10.");
  assert.equal(result.metadata.mathCount, 2);
  assert.match(result.html, /aria-label="x"/);
  assert.match(result.html, /aria-label="y"/);
  assert.ok(result.html.includes("$5"));
  assert.ok(result.html.includes("$10"));
});

test("table pipes remain delimiters: authors must use LaTeX absolute-value commands", () => {
  const bad = render("| condition |\n| --- |\n| $|x|<1$ |");
  const good = render(String.raw`| condition |
| --- |
| $\lvert x\rvert<1$ |`);
  assert.equal(bad.metadata.mathCount, 0);
  assert.equal(good.metadata.mathCount, 1);
  assert.equal(good.metadata.mathErrorCount, 0);
});

test("real export fixture contains working CJK emphasis and math without consuming prices", () => {
  const source = readFileSync(new URL("../../../ScopyTests/Fixtures/markdown_delimiter_repro.md", import.meta.url), "utf8");
  const result = render(source);
  assert.equal(result.metadata.mathCount, 5);
  assert.equal(result.metadata.mathErrorCount, 0);
  assert.match(result.html, /<strong>重点。<\/strong>/);
  assert.match(result.html, /<strong>“重要结论”<\/strong>/);
  assert.match(result.html, /<strong><span class="scopy-math-host/);
  for (const price of ["$5", "$10", "$19.99", "$9.99"]) assert.ok(result.html.includes(price));
});
