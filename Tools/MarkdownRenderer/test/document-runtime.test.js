import assert from "node:assert/strict";
import test from "node:test";
import { tableColumnSize } from "../src/documentRuntime.js";

// The contract's pipe-table bucket thresholds (collapsed-whitespace text length per column).
test("table column buckets follow the contract thresholds", () => {
  assert.deepEqual([0, 40, 41, 100, 101, 160, 161, 5000].map(tableColumnSize), ["sm", "sm", "md", "md", "lg", "lg", "xl", "xl"]);
});
