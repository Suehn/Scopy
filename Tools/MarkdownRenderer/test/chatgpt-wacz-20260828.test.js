import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";

test("ChatGPT contract: only paired double tildes create deletion", () => {
  const result = render("Keep ~one tilde~ literal; render ~~two tildes~~ as deletion.");

  assert.match(result.html, /Keep ~one tilde~ literal/);
  assert.match(result.html, /<del>two tildes<\/del>/);
  assert.doesNotMatch(result.html, /<del>one tilde<\/del>/);
});

test("ChatGPT contract: single-dollar delimiters stay literal while explicit math renders", () => {
  const result = render([
    "Single-dollar $x + 1$ stays literal.",
    "",
    "Backslash inline: \\(a + b\\).",
    "",
    "\\[c + d\\]",
    "",
    "$$",
    "e + f",
    "$$"
  ].join("\n"));

  assert.match(result.html, /\$x \+ 1\$/);
  assert.equal(result.metadata.mathCount, 3);
  assert.match(result.html, /<span class="katex">/);
  assert.match(result.html, /class="katex-display"/);
  assert.match(result.html, /aria-label="a \+ b"/);
  assert.match(result.html, /aria-label="c \+ d"/);
  assert.match(result.html, /aria-label="e \+ f"/);
  assert.doesNotMatch(result.html, /class="katex-mathml"/);
});

test("ChatGPT contract: language-math fences render as display math", () => {
  const result = render(["```math", "x^2 + y^2 = z^2", "```"].join("\n"));

  assert.match(result.html, /class="katex-display"/);
  assert.match(result.html, /aria-label="x\^2 \+ y\^2 = z\^2/);
  assert.match(result.html, /data-math-source="x\^2 \+ y\^2 = z\^2/);
  assert.doesNotMatch(result.html, /<pre><code/);
});

test("raw HTML blocks remain literal and scripts never survive as elements", () => {
  const source = "<div>box</div> <span>inline</span> <kbd>Cmd</kbd> <script>globalThis.__scopyPwned = true</script>";
  const result = render(source);

  assert.match(result.html, /&#x3C;div>box&#x3C;\/div>/);
  assert.match(result.html, /&#x3C;span>inline&#x3C;\/span>/);
  assert.match(result.html, /&#x3C;kbd>Cmd&#x3C;\/kbd>/);
  assert.match(result.html, /&#x3C;script>globalThis\.__scopyPwned = true&#x3C;\/script>/);
  assert.doesNotMatch(result.html, /<script(?:\s|>)/i);
});

test("ChatGPT contract: four-backtick fences preserve a nested three-backtick fence", () => {
  const result = render([
    "````markdown",
    "```js",
    "const answer = 42;",
    "```",
    "````"
  ].join("\n"));

  assert.match(result.html, /<pre><code class="hljs language-markdown">/);
  assert.match(result.html, /```js/);
  assert.match(result.html, /const answer = 42;/);
  assert.match(result.html, /```<\/span>/);
  assert.equal((result.html.match(/<pre>/g) || []).length, 1);
});

test("ChatGPT contract: escaped table pipes stay in-cell and unescaped |r| splits cells", () => {
  const result = render([
    "| expression | note |",
    "| --- | --- |",
    "| `a \\| b` | escaped |",
    "| |r| | unescaped |"
  ].join("\n"));

  assert.match(result.html, /<td><code>a \| b<\/code><\/td>\s*<td>escaped<\/td>/);
  assert.match(result.html, /<tr>\s*<td><\/td>\s*<td>r<\/td>\s*<\/tr>/);
  assert.doesNotMatch(result.html, /<td>unescaped<\/td>/);
});

test("ChatGPT contract: task lists retain checked and unchecked disabled controls", () => {
  const result = render("- [x] shipped\n- [ ] pending");

  assert.match(result.html, /<ul class="contains-task-list">/);
  assert.match(result.html, /<input type="checkbox" checked disabled> shipped/);
  assert.match(result.html, /<input type="checkbox" disabled> pending/);
});

test("Scopy stability contract: footnote hrefs and IDs share one namespace", () => {
  const result = render("Text[^A] and again[^A].\n\n[^A]: Note");

  assert.match(result.html, /href="#scopy-fn-a" id="scopy-fnref-a"/);
  assert.match(result.html, /href="#scopy-fn-a" id="scopy-fnref-a-2"/);
  assert.match(result.html, /<li id="scopy-fn-a">/);
  assert.match(result.html, /href="#scopy-fnref-a"/);
  assert.equal((result.html.match(/data-footnote-ref/g) || []).length, 2);
  assert.equal((result.html.match(/data-footnote-backref/g) || []).length, 2);
  assert.doesNotMatch(result.html, /scopy-link--(?:internal|external|file)|scopy-icon--external-link/);
  assert.doesNotMatch(result.html, /user-content-user-content/);
});

test("ChatGPT contract: RTL, CJK, combining marks, and emoji are lossless", () => {
  const text = "עברית العربية 中文 e\u0301 👩🏽‍💻 🏳️‍🌈";
  const result = render(text);

  assert.match(result.html, new RegExp(escapeRegExp(text)));
});

test("ChatGPT contract: a long unbroken token is never renderer-truncated", () => {
  const token = `token-${"a".repeat(100_000)}-end`;
  const result = render(token);

  assert.equal(result.html, `<p>${token}</p>`);
  assert.equal(result.html.length, token.length + "<p></p>".length);
});

test("ChatGPT contract: math hosts expose source semantics and contain HTML-only KaTeX", () => {
  const source = "x + y";
  const result = render(`\\(${source}\\)`);

  assert.match(result.html, /role="math"/);
  assert.match(result.html, /aria-label="x \+ y"/);
  assert.match(result.html, /data-math-source="x \+ y"/);
  assert.match(result.html, /class="katex-html"/);
  assert.doesNotMatch(result.html, /class="katex-mathml"/);
  assert.doesNotMatch(result.html, /<math(?:\s|>)/);
});

function escapeRegExp(text) {
  return String(text).replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}
