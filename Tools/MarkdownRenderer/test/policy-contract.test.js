import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { render } from "../src/render.js";

// The app embeds exactly this payload (bytes pinned by Swift MarkdownRenderingCorpusContractTests
// against the same fixture); here the renderer must accept each payload and act on it.
const contract = JSON.parse(readFileSync(new URL("./fixtures/policy-contract.json", import.meta.url), "utf8"));
const rendererPolicyKeys = ["allowLooseMathRepair", "linkEnrichment"];

for (const testCase of contract.cases) {
  test(`policy contract: ${testCase.name}`, () => {
    const policy = JSON.parse(testCase.payload);
    for (const key of Object.keys(policy)) {
      assert.ok(rendererPolicyKeys.includes(key), `unexpected policy key ${key}`);
    }
    if (testCase.linkEnrichment && Object.keys(testCase.linkEnrichment).length > 0) {
      assert.deepEqual(policy.linkEnrichment, testCase.linkEnrichment, "URL keys round-trip through the default slash escaping");
    } else {
      assert.equal("linkEnrichment" in policy, false);
    }

    const result = render(contract.source, policy);
    assert.equal(result.metadata.repairedMathCount, testCase.expectedRepairedMathCount);
    assert.equal(/scopy-rich-news/.test(result.html), testCase.expectsNewsCards);
  });
}
