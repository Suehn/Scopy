import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fromHtmlIsomorphic as fromHtml } from "hast-util-from-html-isomorphic";
import { render } from "../src/render.js";
import { codexFileIcon, codexPluginIcon, localFileKind } from "../src/scopyCodexIcons.js";

const fixtureRoot = new URL("./fixtures/", import.meta.url);
const cases = {
  "report.docx": "artifactDocument", "source.swift": "code", "README.md": "document",
  "unknown.xyz": "file", "theme.css": "css", "main.cpp": "cplusplus", "archive.zip": "folder",
  "index.html": "html", "Main.java": "java", "script.js": "javascript", "image.png": "image",
  "config.yml": "yaml", "data.json": "json", "analysis.ipynb": "notebook", "report.pdf": "pdf",
  "index.php": "php", "script.py": "python", "App.tsx": "react", "main.rs": "rust",
  "run.sh": "shell", "SKILL.md": "skill", "model.xlsx": "spreadsheet", "Makefile": "build",
  "deck.pptx": "presentation", "checksum.sha256": "hashes", "Dockerfile": "terminal",
  "main.ts": "typescript", "config.toml": "toml", "clip.mp4": "video", "music.wav": "audio"
};
function allNodes(root) { return [root, ...(root.children || []).flatMap(allNodes)]; }

test("every extracted file and application icon keeps its original geometry and paint", () => {
  for (const [dir, dataFile, create] of [
    ["codex-icons", "codexFileIconAssets", (key) => codexFileIcon(key, 0)],
    ["codex-plugin-icons", "codexPluginIconAssets", (key) => codexPluginIcon(`app://${key}`, 0)]
  ]) {
    const data = JSON.parse(readFileSync(new URL(`../src/${dataFile}.json`, import.meta.url)));
    const manifest = JSON.parse(readFileSync(new URL(`${dir}/manifest.json`, fixtureRoot)));
    for (const [key, source] of Object.entries(data.icons)) {
      const svg = readFileSync(new URL(`${dir}/${key}.svg`, fixtureRoot));
      assert.equal(createHash("sha256").update(svg).digest("hex"), manifest.entries[key].svgSha256, key);
      const icon = create(key);
      assert.equal(icon.properties.viewBox, source.properties.viewBox, key);
      const emitted = allNodes(icon), original = allNodes(source);
      assert.equal(emitted.length, original.length, key);
      for (let i = 0; i < original.length; i++) {
        assert.equal(emitted[i].tagName, original[i].tagName, key);
        for (const [property, value] of Object.entries(original[i].properties || {})) {
          if (property === "id" || String(value).includes("url(#")) continue;
          assert.deepEqual(emitted[i].properties[property], value, `${key}.${property}`);
        }
      }
    }
  }
});

test("local file types select distinct Codex artwork, with explicit media attachment adaptation", () => {
  for (const [name, kind] of Object.entries(cases)) {
    const path = `/tmp/${name}`;
    assert.equal(localFileKind(path), kind, name);
    assert.equal(localFileKind(`${path}:12:3`), kind, name);
    assert.match(render(`[${name}](${path})`).html, new RegExp(`data-scopy-file-kind="${kind}"`));
  }
  assert.equal(localFileKind("/tmp/folder/"), "folder");
  assert.equal(localFileKind("/tmp/图%20片.PNG"), "image");
  assert.equal(localFileKind("/tmp/file.pdf.exe"), "file");
});

test("repeated gradient and masked brands retain unique live paint references after serialization", () => {
  const markdown = Array(3).fill("[Word](/tmp/report.docx) [Sheets](app://google-sheets) [Slides](plugin:google-slides)").join(" ");
  const first = render(markdown).html;
  assert.equal(render(markdown).html, first);
  const nodes = allNodes(fromHtml(first, { fragment: true }));
  const ids = nodes.flatMap((node) => node.properties?.id ? [node.properties.id] : []);
  assert.ok(ids.length > 12);
  assert.equal(new Set(ids).size, ids.length);
  for (const node of nodes) {
    for (const value of Object.values(node.properties || {})) {
      for (const match of String(value).matchAll(/url\(#([^)]*)\)/g)) assert.ok(ids.includes(match[1]), match[1]);
    }
  }
  assert.ok(nodes.some((node) => node.tagName === "mask"));
  assert.ok(nodes.some((node) => node.tagName === "filter"));
  assert.doesNotMatch(first, /scopy-icon--puzzle-piece/);
  assert.match(first, /scopy-link--plugin" aria-disabled="true"/);
});

test("plugin package URLs preserve Codex brands across both plugin syntaxes", () => {
  for (const prefix of ["plugin:", "plugin://", "app://"]) {
    for (const key of ["github", "google-sheets", "figma"]) {
      const html = render(`[App](${prefix}${key}@openai-curated-remote)`).html;
      assert.ok(html.includes(`scopy-codex-plugin--${key}`));
      assert.ok(!html.includes("scopy-icon--globe"));
    }
  }
  assert.equal(localFileKind("/tmp/constructor"), "file");
});
