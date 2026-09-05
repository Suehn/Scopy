import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";

test("renders GFM links, tables, task lists, and explicit math", () => {
  const result = render(`
# Title

- [x] done
- [doc](/Users/alice/project/file.md:25)

| a | b |
| --- | --- |
| \\(x_1\\) | 2 |
`);

  assert.match(result.html, /<h1>Title<\/h1>/);
  assert.match(result.html, /class="contains-task-list"/);
  assert.match(result.html, /href="scopy-file:\/Users\/alice\/project\/file.md:25"/);
  assert.match(result.html, /data-scopy-file-kind="document"/);
  assert.match(result.html, /<table>/);
  assert.match(result.html, /katex/);
});

test("keeps table code spans with pipe examples inside their source cells", () => {
  const result = render(`
| Example | Notes |
| --- | --- |
| \`| A | B |\` | ok |
| \`A | B\` | ok |
`);

  assert.match(result.html, /<td><code>\| A \| B \|<\/code><\/td>\s*<td>ok<\/td>/);
  assert.match(result.html, /<td><code>A \| B<\/code><\/td>\s*<td>ok<\/td>/);
  assert.doesNotMatch(result.html, /<td>`<\/td>/);
  assert.doesNotMatch(result.html, /<td>`A<\/td>/);
});

test("leaves escaped table code-span pipes and non-table paragraphs stable", () => {
  const result = render([
    "Paragraph `A | B` should stay literal.",
    "",
    "| Example | Notes |",
    "| --- | --- |",
    "| `A \\| B` | ok |"
  ].join("\n"));

  assert.match(result.html, /<p>Paragraph <code>A \| B<\/code> should stay literal.<\/p>/);
  assert.match(result.html, /<td><code>A \| B<\/code><\/td>\s*<td>ok<\/td>/);
});

test("keeps table fence-marker examples as cell text", () => {
  const result = render([
    "| 模块 | 示例 1 | 示例 2 | 推荐 |",
    "| --- | --- | --- | --- |",
    "| 代码块 | ```python | ```bash | 高 |"
  ].join("\n"));

  assert.match(result.html, /<td>```python<\/td>\s*<td>```bash<\/td>\s*<td>高<\/td>/);
  assert.doesNotMatch(result.html, /```python \| ```bash/);
});

test("preserves supported custom plugin links without widening file URL links", () => {
  const plugin = render("[@电脑](plugin://computer-use@openai-bundled)");
  const fileURL = render("[file](file:///Users/ziyi/a.md)");

  assert.match(plugin.html, /href="plugin:\/\/computer-use@openai-bundled"/);
  assert.doesNotMatch(plugin.html, /scopy-link--external|scopy-icon--external-link/);
  assert.doesNotMatch(fileURL.html, /href="file:\/\/\/Users\/ziyi\/a.md"/);
});

test("sanitizes network link protocols to http, https, and inert app or plugin mentions", () => {
  const result = render("[web](https://example.com) [mail](mailto:test@example.com) [script](javascript:alert(1)) [plugin](plugin:asset)");

  assert.match(result.html, /href="https:\/\/example\.com"/);
  assert.match(result.html, /href="https:\/\/example\.com" class="scopy-link scopy-link--external"/);
  assert.match(result.html, /<svg class="scopy-icon scopy-icon--globe scopy-link-origin-icon"[^>]*><path[^>]+d="[^"]+" fill="currentColor"><\/path><\/svg>/);
  assert.match(result.html, /href="plugin:asset"/);
  assert.doesNotMatch(result.html, /href="plugin:asset"[^>]*scopy-link--external/);
  assert.doesNotMatch(result.html, /href="mailto:/);
  assert.doesNotMatch(result.html, /href="javascript:/);
});

test("placeholder URL prose is not promoted to an external link", () => {
  const result = render("目标不是 https://...，而是这次会话沙箱里生成的附件。");

  assert.doesNotMatch(result.html, /scopy-link--external|scopy-icon--external-link/);
  assert.match(result.html, /class="scopy-link scopy-link--inert"/);
  assert.match(result.html, />https:\/\/\.\.\.，而是这次会话沙箱里生成的附件。<\/a>/);
});

test("Codex links add real SVG affordance, resolve absolute and tilde files, and keep relative files inert", () => {
  const result = render([
    "[web](https://example.com/path)",
    "[relative](docs/guide.md)",
    "[dot-relative](./docs/guide.md)",
    "[fragment](#section)",
    "[local](/Users/alice/file.md:4)",
    "[tilde](~/Documents/tool.swift:3:9)",
    "[plugin](plugin:asset)",
    "[credentials](https://user:password@example.com/private)",
    "[encoded-control](https://example.com/line%0Abreak)",
    `[utf8-oversized](https://example.com/${"界".repeat(2_725)})`
  ].join(" "));

  assert.match(result.html, /href="https:\/\/example\.com\/path" class="scopy-link scopy-link--external"/);
  assert.match(result.html, /class="scopy-icon scopy-icon--globe scopy-link-origin-icon"[^>]+aria-hidden="true"/);
  assert.doesNotMatch(result.html, /↗|&#x2197;|&#8599;/);
  assert.match(result.html, /<a class="scopy-link scopy-link--file scopy-link--file-inert" data-scopy-file-kind="document" aria-disabled="true"><span class="scopy-mention-icon"><svg[^>]*scopy-codex-icon--document[^>]*>/);
  assert.doesNotMatch(result.html, /href="(?:\.\/)?docs\/guide\.md"/);
  assert.match(result.html, /href="#section" class="scopy-link scopy-link--internal"/);
  assert.match(result.html, /href="scopy-file:\/Users\/alice\/file\.md:4" class="scopy-link scopy-link--file scopy-link--file-resolvable" data-scopy-file-kind="document"/);
  assert.match(result.html, /href="scopy-file:\/~\/Documents\/tool\.swift:3:9" class="scopy-link scopy-link--file scopy-link--file-resolvable" data-scopy-file-kind="code"/);
  assert.match(result.html, /href="plugin:asset" class="scopy-link scopy-link--plugin"/);
  assert.match(result.html, /href="https:\/\/user:password@example\.com\/private" class="scopy-link scopy-link--inert"/);
  assert.match(result.html, /href="https:\/\/example\.com\/line%0Abreak" class="scopy-link scopy-link--inert"/);
  assert.equal((result.html.match(/scopy-link-origin-icon/g) || []).length, 1);
});

test("raw scopy-file, file, and javascript schemes cannot inject navigable links", () => {
  const result = render([
    "[raw-scopy](scopy-file:/etc/passwd)",
    "[raw-file](file:///etc/passwd)",
    "[raw-javascript](javascript:alert(1))"
  ].join(" "));

  assert.doesNotMatch(result.html, /href="(?:scopy-file|file|javascript):/i);
  assert.equal((result.html.match(/class="scopy-link scopy-link--inert"/g) || []).length, 3);
  assert.doesNotMatch(result.html, /scopy-link--file|scopy-file-icon|scopy-icon--external-link/);
});

test("renders fenced code blocks with highlight.js compatible token classes", () => {
  const result = render("```js\nconst answer = 42;\nconsole.log(`value=${answer}`);\n```");

  assert.match(result.html, /<pre><code class="hljs language-js">/);
  assert.match(result.html, /class="hljs-keyword"/);
  assert.match(result.html, /class="hljs-number"/);
  assert.match(result.html, /class="hljs-title function_"/);
  assert.doesNotMatch(result.html, /<script>/);
});

test("keeps explicit plain text fences unhighlighted", () => {
  const result = render("```text\nconst answer = 42;\n```");

  assert.match(result.html, /<pre><code class="language-text">const answer = 42;\n<\/code><\/pre>/);
  assert.doesNotMatch(result.html, /class="hljs/);
});

test("renders long Chinese reference-style markdown notes", () => {
  const result = render(`
# 笔记：为什么宽基指数长期往往优于大多数主动投资

**先把结论说准确。**
更严谨的说法不是“宽基指数在大多数年份都赢主动投资”，而是：**在足够长的持有期里，传统、低成本、宽分散的指数基金，通常会跑赢大多数主动基金。**([投资者.gov][1])

## 一、先把概念讲清楚：这里说的“宽基指数”到底是什么

这份笔记里，我把“宽基指数”限定为：**跟踪传统、覆盖面较广、分散程度较高的市场指数基金**。

[1]: https://www.investor.gov/introduction-investing/investing-basics/glossary/index-fund "Index Fund | Investor.gov"
`);

  assert.match(result.html, /<h1>笔记：为什么宽基指数长期往往优于大多数主动投资<\/h1>/);
  assert.match(result.html, /<strong>先把结论说准确。<\/strong>/);
  assert.match(result.html, /href="https:\/\/www.investor.gov\/introduction-investing\/investing-basics\/glossary\/index-fund"/);
  assert.doesNotMatch(result.html, /^# 笔记/m);
});

test("promotes parenthesized reference-style source links to citation pills", () => {
  const result = render(`
**今天要闻**

1. **美国在印太对华措辞转温和**：美国防长重申印太承诺。([AP News][1])
2. **油价与通胀受伊朗局势牵动**：市场关注霍尔木兹海峡。([Reuters][2])

[1]: https://apnews.com/article/d6cf2b964940f47a83f0a6f587c7e0c3?utm_source=chatgpt.com "Hegseth reassures Pacific allies"
[2]: https://www.reuters.com/markets/example?utm_source=chatgpt.com "Reuters source"
`);

  assert.match(result.html, /<a href="https:\/\/apnews\.com\/article\/d6cf2b964940f47a83f0a6f587c7e0c3\?utm_source=chatgpt\.com" title="Hegseth reassures Pacific allies" class="scopy-source-citation-link" data-scopy-source-citation="true" aria-label="AP News">/);
  assert.match(result.html, /class="scopy-source-citation-label">AP News<\/span>/);
  assert.match(result.html, /class="scopy-source-citation-label">Reuters<\/span>/);
  assert.match(result.html, /class="scopy-icon scopy-icon--globe scopy-source-citation-origin-icon"/);
  assert.doesNotMatch(result.html, /scopy-link--external|scopy-icon--external-link|scopy-link__label/);
  assert.doesNotMatch(result.html, /\(<a href="https:\/\/apnews\.com/);
  assert.doesNotMatch(result.html, /AP News<\/a>\)/);
});

test("does not promote encoded-control citation destinations", () => {
  const result = render("Unsafe source.([AP News](https://example.com/line%0Abreak))");

  assert.doesNotMatch(result.html, /scopy-source-citation-link/);
  assert.doesNotMatch(result.html, /scopy-link--external|scopy-icon--external-link/);
  assert.match(result.html, />AP News<\/a>/);
});

test("keeps ordinary parenthesized markdown links as normal links", () => {
  const result = render("Read the docs ([guide][1]) before changing code.\n\n[1]: https://example.com/guide");

  assert.match(result.html, /\(<a href="https:\/\/example\.com\/guide" class="scopy-link scopy-link--external"><svg class="scopy-icon scopy-icon--globe scopy-link-origin-icon"[^>]*>.*?<\/svg><span class="scopy-link__label">guide<\/span>/);
  assert.doesNotMatch(result.html, /scopy-source-citation-link/);
});

test("citations use the closed bundled favicon map by exact host and never fetch", () => {
  const result = render(`
Mapped hosts.([OpenAI][1], [Reuters][2]) Unknown host.([AP News][3])

[1]: https://help.openai.com/en/articles/9237897?utm_source=chatgpt.com
[2]: https://www.reuters.com/markets/example?utm_source=chatgpt.com
[3]: https://apnews.com/article/example?utm_source=chatgpt.com
`);

  assert.match(result.html, /<img src="rich\/favicon-help-openai-32\.png" alt="" class="scopy-source-citation-origin-icon scopy-source-citation-favicon">/);
  assert.match(result.html, /<img src="rich\/favicon-reuters-32\.png" alt="" class="scopy-source-citation-origin-icon scopy-source-citation-favicon">/);
  assert.match(result.html, /class="scopy-icon scopy-icon--globe scopy-source-citation-origin-icon"/);
  assert.doesNotMatch(result.html, /<img[^>]+src="https?:\/\//i);
});

test("collapses multi-source citation groups to first source plus count", () => {
  const result = render(`
1. Item with two sources.([AP News][1], [Reuters][2])
2. Item with explicit count.([AP News +1][1])

[1]: https://apnews.com/article/cac5206df0f0c7b79fe9321c08d63096?utm_source=chatgpt.com
[2]: https://www.reuters.com/markets/example?utm_source=chatgpt.com
`);

  assert.match(result.html, /class="scopy-source-citation-count" aria-label="1 additional source">\+1<\/span>/);
  assert.match(result.html, /class="scopy-source-citation-supporting" role="list" aria-label="Supporting sources"/);
  assert.match(result.html, /class="scopy-source-citation-supporting-link" aria-label="Supporting source: Reuters"/);
  assert.match(result.html, />Reuters<\/a>/);
  assert.doesNotMatch(result.html, /AP News \+1<\/a>/);
  assert.doesNotMatch(result.html, /data-scopy-source-count/);
});

test("renders the captured domain-style source label as a compact plus-count pill", () => {
  const result = render(`
QQQ quote.([investing.com][1], [Google Finance][2])

[1]: https://www.investing.com/etfs/powershares-qqqq
[2]: https://www.google.com/finance/quote/QQQ:NASDAQ
`);

  assert.match(result.html, /class="scopy-source-citation-label">investing\.com<\/span>/);
  assert.match(result.html, /class="scopy-source-citation-count" aria-label="1 additional source">\+1<\/span>/);
  assert.match(result.html, /class="scopy-source-citation-supporting-link" aria-label="Supporting source: Google Finance"/);
  assert.doesNotMatch(result.html, />Google Finance<\/a>\)/);
});

test("keeps unsupported and compact raw HTML as visible literal text", () => {
  const result = render("<script>alert(1)</script>\n\n<details><summary>x</summary>y</details>");

  assert.match(result.html, /&#x3C;script>alert\(1\)&#x3C;\/script>/);
  assert.match(result.html, /&#x3C;details>&#x3C;summary>x&#x3C;\/summary>y&#x3C;\/details>/);
  assert.doesNotMatch(result.html, /<script(?:\s|>)/i);
  assert.doesNotMatch(result.html, /<details(?:\s|>)/i);
});

test("renders backslash inline and display math", () => {
  const result = render("Inline \\(x_1 + y\\)\n\n\\[\\int_0^1 x dx\\]");

  assert.equal(result.metadata.warnings.length, 0);
  assert.equal(result.metadata.mathCount, 2);
  assert.match(result.html, /katex/);
  assert.match(result.html, /katex-display/);
  assert.match(result.html, /class="scopy-math-host scopy-math-inline-host"/);
  assert.match(result.html, /class="scopy-math-host scopy-math-display-host"/);
  assert.doesNotMatch(result.html, /\\\(x_1 \+ y\\\)/);
});

test("keeps single-line double-dollar math inline", () => {
  const result = render("$$E=mc^2$$");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /class="scopy-math-host scopy-math-inline-host"/);
  assert.doesNotMatch(result.html, /katex-display/);
});

test("renders standalone multiline double-dollar math as display", () => {
  const result = render("$$\nE=mc^2\n$$");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /class="scopy-math-host scopy-math-display-host"/);
  assert.match(result.html, /katex-display/);
});

test("classifies strict, relaxed, and malformed math by final KaTeX outcome", () => {
  const strict = render(String.raw`\(x + y\)`);
  const relaxed = render(String.raw`\(emoji 😀\)`);
  const malformed = render(String.raw`\[\frac{\]`);
  const unknown = render(String.raw`\[\doesnotexist{x}\]`);

  assert.deepEqual(
    [strict.metadata.mathStrictCount, strict.metadata.mathRelaxedCount, strict.metadata.mathErrorCount],
    [1, 0, 0]
  );
  assert.deepEqual(
    [relaxed.metadata.mathStrictCount, relaxed.metadata.mathRelaxedCount, relaxed.metadata.mathErrorCount],
    [0, 1, 0]
  );
  for (const result of [malformed, unknown]) {
    assert.deepEqual(
      [result.metadata.mathStrictCount, result.metadata.mathRelaxedCount, result.metadata.mathErrorCount],
      [0, 0, 1]
    );
    assert.equal(
      result.metadata.mathStrictCount + result.metadata.mathRelaxedCount + result.metadata.mathErrorCount,
      result.metadata.mathCount
    );
    assert.match(result.html, /class="katex-error"/);
  }
});

test("renders multiline backslash display math", () => {
  const result = render("\\[\n\\int_0^1 x dx\n\\]");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /katex-display/);
  assert.doesNotMatch(result.html, /content-visibility|contain-intrinsic-size/);
  assert.doesNotMatch(result.html, /\[<br>/);
});

test("preserves malformed and empty backslash delimiters literally", () => {
  const result = render("before \\(x after\n\nempty \\(\\)\n\nclose \\) and \\]\n\n\\[\nunclosed");

  assert.equal(result.metadata.mathCount, 0);
  assert.ok(result.html.includes("before \\(x after"));
  assert.ok(result.html.includes("empty \\(\\)"));
  assert.ok(result.html.includes("close \\) and \\]"));
  assert.ok(result.html.includes("\\[<br>\nunclosed"));
});

test("keeps the complete long math source on its semantic host", () => {
  const source = `x${" ".repeat(4_200)}z`;
  const result = render(`\\(${source}\\)`);
  const match = /data-math-source="([^"]*)"/.exec(result.html);

  assert.equal(result.metadata.mathCount, 1);
  assert.ok(match);
  assert.equal(match[1], source);
});

test("caps user-declared KaTeX geometry without truncating source semantics", () => {
  const source = String.raw`\rule{100000em}{100000em}`;
  const result = render(`\\[${source}\\]`);

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /data-math-source="\\rule\{100000em\}\{100000em\}"/);
  assert.doesNotMatch(result.html, /(?:height|width):100000em/);
  assert.match(result.html, /(?:height|width):20em/);
});

test("does not rewrite backslash math inside code or links", () => {
  const result = render("`\\(code\\)` [\\(label\\)](/tmp/\\(path\\).md)\n\nReal \\(x\\)");

  assert.equal(result.metadata.mathCount, 1);
  assert.match(result.html, /<code>\\\(code\\\)<\/code>/);
  assert.match(result.html, /href="scopy-file:\/tmp\/\(path\).md"/);
  assert.match(result.html, /<span class="scopy-link__label">\(label\)<\/span><\/a>/);
  assert.match(result.html, /katex/);
});

test("renders the closed inline safe-tag extension without parsing code fences", () => {
  const result = render("Text <kbd>Cmd</kbd> and <mark>hot</mark>\n\n```\n<kbd>code</kbd>\n```");

  assert.match(result.html, /Text <kbd class="scopy-safe-html-kbd">Cmd<\/kbd> and <mark class="scopy-safe-html-mark">hot<\/mark>/);
  assert.match(result.html, /<code>&#x3C;kbd>code&#x3C;\/kbd>/);
  assert.equal((result.html.match(/<kbd class=/g) || []).length, 1);
  assert.equal((result.html.match(/<mark class=/g) || []).length, 1);
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
  assert.match(result.html, /href="scopy-file:\/tmp\/file_1.md"/);
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
