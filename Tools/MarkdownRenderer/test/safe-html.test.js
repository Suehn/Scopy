import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";

test("closed inline safe tags preserve same-parse Markdown phrasing children", () => {
  const result = render("<u>under **bold**</u> <kbd>Cmd</kbd> <mark>hot</mark> H<sub>2</sub> x<sup>2</sup>");

  assert.match(result.html, /<u class="scopy-safe-html-u">under <strong>bold<\/strong><\/u>/);
  assert.match(result.html, /<kbd class="scopy-safe-html-kbd">Cmd<\/kbd>/);
  assert.match(result.html, /<mark class="scopy-safe-html-mark">hot<\/mark>/);
  assert.match(result.html, /H<sub class="scopy-safe-html-sub">2<\/sub>/);
  assert.match(result.html, /x<sup class="scopy-safe-html-sup">2<\/sup>/);
});

test("inline safe tags pair with one nested stack and fail the phrasing region closed on mismatch", () => {
  const valid = render("<u>a <mark>b</mark> c</u>");
  const mismatch = render("<u>a <mark>b</u> c</mark>");

  assert.match(valid.html, /<u class="scopy-safe-html-u">a <mark class="scopy-safe-html-mark">b<\/mark> c<\/u>/);
  assert.match(mismatch.html, /&#x3C;u>a &#x3C;mark>b&#x3C;\/u> c&#x3C;\/mark>/);
  assert.doesNotMatch(mismatch.html, /scopy-safe-html/);
});

test("inline safe tags cannot wrap flow content", () => {
  const result = render(["<u>", "", "# Heading", "", "- item", "", "</u>"].join("\n"));

  assert.match(result.html, /^&#x3C;u>\n<h1>Heading<\/h1>/);
  assert.match(result.html, /<ul>[\s\S]*<li>item<\/li>[\s\S]*<\/ul>\n&#x3C;\/u>$/);
  assert.doesNotMatch(result.html, /<u class=/);
});

test("attributes and unsupported raw elements remain text even inside a valid safe wrapper", () => {
  const attributes = render("<u onclick=\"globalThis.pwned=1\">x</u> <mark style=\"position:fixed\">y</mark>");
  const script = render("<u>a<script>globalThis.pwned=1</script>b</u>");

  assert.match(attributes.html, /&#x3C;u onclick="globalThis\.pwned=1">x&#x3C;\/u>/);
  assert.match(attributes.html, /&#x3C;mark style="position:fixed">y&#x3C;\/mark>/);
  assert.doesNotMatch(attributes.html, /scopy-safe-html|<(?:u|mark)(?:\s|>)/i);
  assert.match(script.html, /<u class="scopy-safe-html-u">a&#x3C;script>globalThis\.pwned=1&#x3C;\/script>b<\/u>/);
  assert.doesNotMatch(script.html, /<script(?:\s|>)/i);
});

test("flow details require one closed header, keep block Markdown children, and preserve open", () => {
  const closed = render([
    "<details> <summary>More</summary>",
    "",
    "- item",
    "- **bold**",
    "",
    "</details>"
  ].join("\n"));
  const open = render("<details open>\n<summary>Visible</summary>\n\nBody\n\n</details>");

  assert.match(closed.html, /^<details class="scopy-safe-details"><summary class="scopy-safe-summary">More<\/summary><ul>/);
  assert.match(closed.html, /<li><strong>bold<\/strong><\/li>/);
  assert.match(closed.html, /<\/ul><\/details>$/);
  assert.match(open.html, /^<details class="scopy-safe-details" open><summary class="scopy-safe-summary">Visible<\/summary><p>Body<\/p><\/details>$/);
});

test("invalid nested details consume their own close without stealing the valid outer close", () => {
  const result = render([
    "<details><summary>Outer</summary>",
    "",
    "<details class=x><summary>Inner</summary>",
    "",
    "inside",
    "",
    "</details>",
    "",
    "outside",
    "",
    "</details>"
  ].join("\n"));

  assert.equal((result.html.match(/<details class="scopy-safe-details"/g) || []).length, 1);
  assert.match(result.html, /^<details class="scopy-safe-details"><summary class="scopy-safe-summary">Outer<\/summary>/);
  assert.match(result.html, /&#x3C;details class=x>&#x3C;summary>Inner&#x3C;\/summary><p>inside<\/p>&#x3C;\/details><p>outside<\/p><\/details>$/);
});

test("valid nested details and flow containers retain their Markdown structure", () => {
  const nested = render([
    "<details><summary>Outer</summary>",
    "",
    "<details><summary>Inner</summary>",
    "",
    "inside",
    "",
    "</details>",
    "",
    "</details>"
  ].join("\n"));
  const list = render("- <details><summary>List</summary>\n\n  body\n\n  </details>");
  const quote = render("> <details><summary>Quote</summary>\n>\n> body\n>\n> </details>");

  assert.equal((nested.html.match(/<details class="scopy-safe-details"/g) || []).length, 2);
  assert.match(nested.html, /Outer<\/summary><details class="scopy-safe-details"><summary class="scopy-safe-summary">Inner<\/summary><p>inside<\/p><\/details><\/details>/);
  assert.match(list.html, /<ul>[\s\S]*<li>\s*<details class="scopy-safe-details">[\s\S]*<p>body<\/p><\/details>\s*<\/li>[\s\S]*<\/ul>/);
  assert.match(quote.html, /<blockquote>\s*<details class="scopy-safe-details">[\s\S]*<p>body<\/p><\/details>\s*<\/blockquote>/);
});

test("details and summary attributes never enter the trusted HAST path", () => {
  const attributes = render([
    "<details open ontoggle=\"globalThis.pwned=1\"><summary onclick=\"globalThis.pwned=2\">Bad</summary>",
    "",
    "<img src=x onerror=\"globalThis.pwned=3\">",
    "",
    "</details>"
  ].join("\n"));
  const scriptBody = render("<details><summary>Safe</summary>\n\n<script>globalThis.pwned=1</script>\n\n</details>");

  assert.doesNotMatch(attributes.html, /<details class="scopy-safe-details"|<img(?:\s|>)/i);
  assert.match(attributes.html, /&#x3C;details open ontoggle=/);
  assert.match(attributes.html, /&#x3C;summary onclick=/);
  assert.match(attributes.html, /&#x3C;img src=x onerror=/);
  assert.match(scriptBody.html, /^<details class="scopy-safe-details"><summary class="scopy-safe-summary">Safe<\/summary>&#x3C;script>globalThis\.pwned=1&#x3C;\/script><\/details>$/);
  assert.doesNotMatch(scriptBody.html, /<script(?:\s|>)/i);
});

test("compact, missing-summary, empty-summary, and unclosed details remain literal", () => {
  const cases = [
    "<details><summary>x</summary>body</details>",
    "<details>\n\nbody\n\n</details>",
    "<details><summary></summary>\n\nbody\n\n</details>",
    "<details><summary>x</summary>\n\nbody"
  ];

  for (const source of cases) {
    const result = render(source);
    assert.doesNotMatch(result.html, /<details class="scopy-safe-details"/);
    assert.match(result.html, /&#x3C;details/);
  }
});

test("complete HTML comments disappear, malformed comments literalize, and code islands remain untouched", () => {
  const result = render([
    "a <!-- hidden --> b",
    "",
    "<!-- multi",
    "line -->",
    "",
    "bad <!-->",
    "",
    "`<!-- inline code -->`",
    "",
    "```html",
    "<!-- fenced code -->",
    "```"
  ].join("\n"));

  assert.match(result.html, /<p>a  b<\/p>/);
  assert.doesNotMatch(result.html, /hidden|multi|line -->/);
  assert.match(result.html, /bad &#x3C;!-->/);
  assert.match(result.html, /<code>&#x3C;!-- inline code -->/);
  assert.match(result.html, /<pre><code class="hljs language-html"><span class="hljs-comment">&#x3C;!-- fenced code --><\/span>/);
});

test("excessive inline nesting degrades literally instead of creating a deep custom tree", () => {
  const depth = 65;
  const result = render("<u>".repeat(depth) + "x" + "</u>".repeat(depth));

  assert.doesNotMatch(result.html, /scopy-safe-html-u/);
  assert.match(result.html, /&#x3C;u>/);
});

test("large malformed inline input remains bounded by the single-pass recognizer", { timeout: 1_500 }, () => {
  const result = render(Array(10_000).fill("<u>").join(" "));

  assert.doesNotMatch(result.html, /scopy-safe-html-u/);
  assert.ok(result.html.length > 80_000);
});
