import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { SCOPY_ICON_NAMES, scopyIcon } from "../src/scopyIcons.js";
import assets from "../src/codexControlIconAssets.json" with { type: "json" };
import { render } from "../src/render.js";

const root = new URL("./fixtures/codex-control-icons/", import.meta.url);
const manifest = JSON.parse(readFileSync(new URL("manifest.json", root)));

test("rich controls retain exact Codex paths and original optical viewBoxes", () => {
  for (const [name, source] of Object.entries(assets.icons)) {
    const svg = readFileSync(new URL(`${name}.svg`, root));
    assert.equal(createHash("sha256").update(svg).digest("hex"), manifest.definitions[name].svgSha256);
    const icon = scopyIcon(name);
    assert.deepEqual(icon.children, source.children, name);
    assert.equal(icon.properties.viewBox, source.properties.viewBox, name);
    assert.equal(icon.properties.ariaHidden, "true", name);
    assert.equal(icon.properties.focusable, "false", name);
    icon.children[0].properties.d = "changed";
    assert.deepEqual(scopyIcon(name).children, source.children, name);
  }
});

test("icon API is closed and no old substitute file/source icons remain", () => {
  for (const name of ["missing", "constructor", "globe", "file-text", "javascript-badge", "puzzle-piece"]) {
    assert.throws(() => scopyIcon(name), /Unknown Scopy icon/);
  }
  assert.equal(SCOPY_ICON_NAMES.length, 8);
});

test("source and image artwork keeps evenodd paint through the HTML sanitizer", () => {
  const html = render("([来源][1])\n\n[1]: https://example.com").html;
  assert.match(html, /fill-rule="evenodd" clip-rule="evenodd"/);
  assert.match(html, /viewBox="0 0 12 12"/);
});

test("rendered rating and map icons keep their inherited paint color", () => {
  const html = render(readFileSync(new URL("../../../ScopyUITests/Fixtures/chatgpt_rich_surfaces.md", import.meta.url), "utf8")).html;
  for (const name of ["star-fill", "map-pin"]) {
    assert.match(html, new RegExp(`<svg class="scopy-icon scopy-icon--${name}"[^>]*fill="currentColor"`));
  }
});
