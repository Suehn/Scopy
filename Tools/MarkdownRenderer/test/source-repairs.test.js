import assert from "node:assert/strict";
import test from "node:test";
import { render } from "../src/render.js";
import { fencePrefix, leadingIndentSpaces } from "../src/scopyLineScan.js";

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

  // 150 family emoji are 150 grapheme clusters (heading-sized) even though they are 1,650 UTF-16 units.
  const families = "👩‍👩‍👧‍👦".repeat(150);
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

test("fence and indentation scanning share one definition", () => {
  assert.deepEqual(fencePrefix("```swift"), { marker: "`", count: 3 });
  assert.deepEqual(fencePrefix("\t ~~~~"), { marker: "~", count: 4 });
  assert.equal(fencePrefix("``"), null);
  assert.equal(fencePrefix("﻿```"), null);
  assert.equal(leadingIndentSpaces("\t  x"), 6);
});
