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
  if (!/^ {0,3}#/.test(line)) {
    return line;
  }
  let hashes = 0;
  let bodyStart = -1;
  let bodyLength = 0;
  // Stop as soon as the prefix or length disqualifies the line. Long prose and flattened
  // tables need no full-line grapheme array, while a combining mark on '#' still belongs
  // to that character rather than being mistaken for a bare heading delimiter.
  for (const { segment, index } of graphemeSegmenter.segment(line)) {
    if (bodyStart === -1) {
      if (hashes === 0 && segment === " ") continue;
      if (segment === "#") {
        hashes += 1;
        if (hashes > 6) return line;
        continue;
      }
      if (hashes === 0 || segment === " " || segment === "\t" || (hashes === 1 && segment === "!")) {
        return line;
      }
      bodyStart = index;
    }
    bodyLength += 1;
    if (bodyLength > MAX_HEADING_GRAPHEMES) return line;
  }
  return bodyStart === -1 ? line : `${line.slice(0, bodyStart)} ${line.slice(bodyStart)}`;
}
