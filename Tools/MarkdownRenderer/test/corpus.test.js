import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { render } from "../src/render.js";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const corpusRoot = new URL("ScopyTests/Fixtures/MarkdownRenderingCorpus/", `file://${repoRoot}/`);
const cases = JSON.parse(readFileSync(new URL("cases.json", corpusRoot), "utf8"));

for (const testCase of cases) {
  test(`corpus: ${testCase.name}`, () => {
    // Non-scientific sources reach render() verbatim; MarkdownRenderingCorpusContractTests pins the
    // profile and policy declared here against the app's detector.
    const source = readFileSync(new URL(testCase.file, corpusRoot), "utf8");
    const result = render(source, { allowLooseMathRepair: testCase.allowLooseMathRepair });

    assert.equal(result.metadata.repairedMathCount, testCase.expectedRepairedMathCount);
    for (const expected of testCase.renderedContains) {
      assert.match(result.html, new RegExp(escapeRegExp(expected)), expected);
    }
    for (const unexpected of testCase.renderedNotContains) {
      assert.doesNotMatch(result.html, new RegExp(escapeRegExp(unexpected)), unexpected);
    }
  });
}

function escapeRegExp(text) {
  return String(text).replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}
