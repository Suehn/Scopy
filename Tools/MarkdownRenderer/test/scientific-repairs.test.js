import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { render } from "../src/render.js";
import { normalizeLatexDocument } from "../src/scopyLatexDocument.js";
import { normalizeLatexInline } from "../src/scopyLatexInline.js";

// Goldens produced by the former Swift implementation; the port must match them byte for byte.
const { cases } = JSON.parse(readFileSync(new URL("./fixtures/scientific-repairs.json", import.meta.url), "utf8"));

for (const testCase of cases) {
  test(`scientific repair: ${testCase.name}`, () => {
    const documentRepaired = testCase.level === "document" ? normalizeLatexDocument(testCase.source) : testCase.source;
    assert.equal(normalizeLatexInline(documentRepaired), testCase.expected);
  });
}

test("the renderer applies the scientific repairs only when the policy asks", () => {
  const source = "\\section{Energy}\n\\textbf{Mass} $\\\\alpha$";
  const plain = render(source).html;
  assert.doesNotMatch(plain, /<h1>|<strong>/);

  const inline = render(source, { allowLatexInlineTextNormalize: true }).html;
  assert.match(inline, /<strong>Mass<\/strong>/);
  assert.match(inline, /data-math-source="\\alpha"/);
  assert.doesNotMatch(inline, /<h1>/);

  const document = render(source, { allowLatexDocumentNormalize: true, allowLatexInlineTextNormalize: true }).html;
  assert.match(document, /<h1>Energy<\/h1>/);
});
