import assert from "node:assert/strict";
import test from "node:test";
import { SCOPY_ICON_NAMES, scopyIcon } from "../src/scopyIcons.js";

const canonicalNames = [
  "puzzle-piece",
  "file-text",
  "javascript-badge",
  "code",
  "image",
  "external-link",
  "globe",
  "close",
  "caret-left",
  "caret-right",
  "caret-up-down"
];

test("creates deterministic decorative HAST for every canonical icon", () => {
  for (const name of canonicalNames) {
    const icon = scopyIcon(name);
    assert.equal(icon.type, "element", name);
    assert.equal(icon.tagName, "svg", name);
    assert.deepEqual(icon.properties.className, ["scopy-icon", `scopy-icon--${name}`], name);
    assert.equal(icon.properties.viewBox, "0 0 256 256", name);
    assert.equal(icon.properties.width, 16, name);
    assert.equal(icon.properties.height, 16, name);
    assert.equal(icon.properties.ariaHidden, "true", name);
    assert.equal(icon.properties.focusable, "false", name);
    assert.equal(icon.children.length, 1, name);
    assert.equal(icon.children[0].tagName, "path", name);
    assert.equal(icon.children[0].properties.fill, "currentColor", name);
    assert.match(icon.children[0].properties.d, /^M/, name);
    assert.equal(icon.children[0].children.length, 0, name);
  }
});

test("document and javascript aliases resolve to the stable canonical classes", () => {
  assert.deepEqual(scopyIcon("document"), scopyIcon("file-text"));
  assert.deepEqual(scopyIcon("javascript"), scopyIcon("javascript-badge"));
  assert.ok(SCOPY_ICON_NAMES.includes("document"));
  assert.ok(SCOPY_ICON_NAMES.includes("javascript"));
});

test("returns fresh HAST objects without exposing shared mutable path data", () => {
  const first = scopyIcon("globe");
  const second = scopyIcon("globe");
  first.properties.className.push("mutated");
  first.children[0].properties.d = "changed";

  assert.deepEqual(second.properties.className, ["scopy-icon", "scopy-icon--globe"]);
  assert.match(second.children[0].properties.d, /^M128,24h0A104/);
});

test("rejects unknown icons and emits no text, styles, or Unicode arrow glyphs", () => {
  assert.throws(() => scopyIcon("missing"), /Unknown Scopy icon: missing/);
  for (const name of SCOPY_ICON_NAMES) {
    const serialized = JSON.stringify(scopyIcon(name));
    assert.doesNotMatch(serialized, /↗|emoji|style/i, name);
    assert.doesNotMatch(serialized, /"type":"text"/, name);
  }
});

test("keeps selected Phosphor Core 2.1.1 path data exact", () => {
  assert.equal(
    scopyIcon("external-link").children[0].properties.d,
    "M200,64V168a8,8,0,0,1-16,0V83.31L69.66,197.66a8,8,0,0,1-11.32-11.32L172.69,72H88a8,8,0,0,1,0-16H192A8,8,0,0,1,200,64Z"
  );
  assert.match(
    scopyIcon("javascript").children[0].properties.d,
    /^M213\.66,82\.34l-56-56.*M80,152v37\.41/s
  );
});
