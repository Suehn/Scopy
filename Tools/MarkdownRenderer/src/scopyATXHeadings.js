import { createFenceTracker } from "./scopyLineScan.js";

// Some Markdown sources omit the CommonMark-required space after `#` (`##标题`), which makes
// heading lines fall back to paragraphs with the wrong inline styles. This repairs that one
// omission before parsing, with the same bounds the Swift MarkdownATXHeadingNormalizer had:
// outside fences, at most three leading spaces (indented code stays code), one to six `#`,
// no `#!` shebang, and a heading-sized remainder of at most 200 grapheme clusters so a
// flattened copied table that starts with a `#` column label never becomes a giant H1.
// Lines are inspected as grapheme clusters, matching Swift `Character` semantics.

const MAX_HEADING_GRAPHEMES = 200;
const graphemeSegmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

export function repairATXHeadings(source) {
  const text = String(source || "");
  if (text.indexOf("#") === -1) {
    return text;
  }
  const fences = createFenceTracker();
  return text
    .split("\n")
    .map((line) => (fences.skip(line) ? line : repairLine(line)))
    .join("\n");
}

function repairLine(line) {
  if (line.indexOf("#") === -1) {
    return line;
  }
  const graphemes = Array.from(graphemeSegmenter.segment(line), (segment) => segment.segment);
  let i = 0;
  let leadingSpaces = 0;
  while (i < graphemes.length && graphemes[i] === " ") {
    leadingSpaces += 1;
    i += 1;
  }
  if (leadingSpaces > 3 || graphemes[i] !== "#") {
    return line;
  }
  let j = i;
  while (j < graphemes.length && graphemes[j] === "#") {
    j += 1;
  }
  const hashCount = j - i;
  if (hashCount > 6 || j >= graphemes.length) {
    return line;
  }
  const next = graphemes[j];
  if (next === " " || next === "\t") {
    return line;
  }
  if (hashCount === 1 && next === "!") {
    return line;
  }
  if (graphemes.length - j > MAX_HEADING_GRAPHEMES) {
    return line;
  }
  return `${graphemes.slice(0, j).join("")} ${graphemes.slice(j).join("")}`;
}
