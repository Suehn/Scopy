import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";

// Source-level repairs that used to run in Swift before the renderer saw the document.
// These tests are the ported MarkdownATXHeadingNormalizer / MarkdownTableCodeSpanPipeNormalizer cases.

test("repairs missing ATX heading whitespace outside code", () => {
  const result = render([
    "#一级标题 `# H1`",
    "##二级标题",
    "",
    "#! /usr/bin/env bash",
    "",
    "    #indented code",
    "",
    "```markdown",
    "###fenced code",
    "```",
    "",
    "~~~~",
    "```",
    "####inner fence example stays code",
    "```",
    "~~~~",
    "",
    "# 已有空格"
  ].join("\n"));

  assert.match(result.html, /<h1>一级标题 <code># H1<\/code><\/h1>/);
  assert.match(result.html, /<h2>二级标题<\/h2>/);
  assert.match(result.html, /<p>#! \/usr\/bin\/env bash<\/p>/);
  assert.match(result.html, /<pre><code>#indented code\n<\/code><\/pre>/);
  assert.match(result.html, /###fenced code/);
  assert.match(result.html, /####inner fence example stays code/);
  assert.match(result.html, /<h1>已有空格<\/h1>/);
  assert.doesNotMatch(result.html, /<h1>!|<h3>fenced|<h4>inner/);
});

test("does not promote a flattened hash column into a giant heading and counts graphemes", () => {
  const flattenedRow = "#" + "实际对象本回答是否真的使用1Markdown heading✅".repeat(12);
  assert.match(render(flattenedRow).html, /<p>#实际对象/);
  assert.doesNotMatch(render(flattenedRow).html, /<h1>/);

  // 200 family emoji meet the exact grapheme limit despite occupying 2,200 UTF-16 units.
  const families = "👩‍👩‍👧‍👦".repeat(200);
  assert.match(render(`#${families}`).html, new RegExp(`<h1>${families}</h1>`));
  assert.doesNotMatch(render(`#${"👩‍👩‍👧‍👦".repeat(201)}`).html, /<h1>/);
});

test("a combining mark after the hash run is read as one grapheme, like Swift Character", () => {
  // "##́x": the second "#" carries the combining acute, so only one bare "#" opens the heading.
  assert.match(render("##́x").html, /<h1>#́x<\/h1>/);
});

test("does not escape pipes inside fenced code blocks that contain a table", () => {
  const fenced = ["```text", "| Example | Notes |", "| --- | --- |", "| `| A | B |` | ok |", "```"].join("\n");
  const result = render(fenced);

  assert.match(result.html, /\| `\| A \| B \|` \| ok \|/);
  assert.doesNotMatch(result.html, /\\\|/);
  assert.doesNotMatch(result.html, /<table>/);
});

test("a fence indented four columns is indented code and does not hide the rest of the document", () => {
  const html = render("    ```\nFormula: \\(x\\)").html;
  assert.match(html, /<pre><code>```\n<\/code><\/pre>/);
  assert.match(html, /data-math-source="x"/);
});

test("source repairs distinguish fence info from a closing fence across profiles", () => {
  const body = "```not a closer\n~~~\n\\section{literal}\n#literal\n\\(x\\)\n\\textbf{literal}";
  const source = `\`\`\`text\n${body}\n\`\`\`\n#after`;
  for (const policy of [{}, { allowLatexDocumentNormalize: true, allowLatexInlineTextNormalize: true }]) {
    const result = render(source, policy);
    assert.equal(result.html, `<pre><code class="language-text">${body}\n</code></pre>\n<h1>after</h1>`);
    assert.equal(result.metadata.mathCount, 0);
  }
});

test("invalid fence openers leave subsequent repairs reachable", () => {
  for (const opener of ["```lang`invalid", "\u00a0~~~", "\t~~~", "    ```"]) {
    assert.match(render(`${opener}\n\n#after`).html, /<h1>after<\/h1>/);
  }
  assert.match(render("```text\r\n#literal\r\n``` \t\r\n#after").html, /#literal\n<\/code><\/pre>\n<h1>after<\/h1>/);
});

test("inline repairs share exact paired backtick spans and ignore escaped openers", () => {
  const policy = { allowLatexDocumentNormalize: true, allowLatexInlineTextNormalize: true };
  const body = "a ` \\(literal\\) ``` \\textbf{literal} \\label{literal}";
  assert.equal(render(`\`\`${body}\`\``, policy).html, `<p><code>${body}</code></p>`);

  for (const source of ["`` \\(x\\) ```", "\\` \\(x\\) `"]) {
    assert.equal(render(source, policy).metadata.mathCount, 1);
  }
  assert.equal(render("`orphan \\textbf{actual}", policy).html, "<p>`orphan <strong>actual</strong></p>");
  const escaped = render("\\``\\(literal\\)` after \\(x\\)", policy);
  assert.match(escaped.html, /<p>`<code>\\\(literal\\\)<\/code>/);
  assert.equal(escaped.metadata.mathCount, 1);

  const linked = render("[label \\(literal\\)](https://example.com/`path) `\\(code\\)` then \\(x\\)", policy);
  assert.match(linked.html, /<code>\\\(code\\\)<\/code>/);
  assert.equal(linked.metadata.mathCount, 1);
});
