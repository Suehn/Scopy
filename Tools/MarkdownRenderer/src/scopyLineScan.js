// One definition of "fence line" and "indentation" for every source-level rewrite that runs
// before parsing and must leave code alone (heading repair, table code-span pipes, backslash
// math). A fence may be indented by at most three columns (a tab counts as four), as in CommonMark:
// four or more make the line indented code, not a fence.

const LEADING_BLANK = /^[\t\p{Zs}]+/u;

/**
 * `{ marker, count }` when `line` is a fence marker line: at most three columns of leading blank,
 * then three or more of the same "`" or "~" character. `null` otherwise.
 */
export function fencePrefix(line) {
  if (leadingIndentSpaces(line) > 3) {
    return null;
  }
  const trimmed = String(line || "").replace(LEADING_BLANK, "");
  const marker = trimmed[0];
  if (marker !== "`" && marker !== "~") {
    return null;
  }
  let count = 0;
  while (count < trimmed.length && trimmed[count] === marker) {
    count += 1;
  }
  return count >= 3 ? { marker, count } : null;
}

/** Leading indentation in columns; a tab counts as four columns. */
export function leadingIndentSpaces(line) {
  let spaces = 0;
  for (const ch of String(line || "")) {
    if (ch === " ") {
      spaces += 1;
      continue;
    }
    if (ch === "\t") {
      spaces += 4;
      continue;
    }
    break;
  }
  return spaces;
}

/**
 * Tracks fenced-code state across the lines of one document. `skip(line)` returns true when the
 * line must be left untouched: it is a fence marker line, or it lies inside an open fence. A fence
 * closes only on a marker of the same character with at least the opening run length.
 */
export function createFenceTracker() {
  let active = null;
  return {
    skip(line) {
      const fence = fencePrefix(line);
      if (fence) {
        if (active) {
          if (active.marker === fence.marker && fence.count >= active.count) {
            active = null;
          }
        } else {
          active = fence;
        }
        return true;
      }
      return active !== null;
    }
  };
}

// The scientific-profile repairs (scopyLatexDocument.js, scopyLatexInline.js) were ported from
// Swift and keep its `Character` line model: "\r\n" is one character, so only a "\n" that does
// not follow "\r" ends a line. Every other source repair splits on "\n".
export function splitCharacterLines(text) {
  const lines = [];
  let start = 0;
  for (let i = text.indexOf("\n"); i >= 0; i = text.indexOf("\n", i + 1)) {
    if (i > 0 && text.charCodeAt(i - 1) === 13) {
      continue;
    }
    lines.push(text.slice(start, i));
    start = i + 1;
  }
  lines.push(text.slice(start));
  return lines;
}

// Swift `.whitespacesAndNewlines`: Unicode Zs, tab, and U+000A-U+000D, U+0085, U+2028, U+2029.
const EDGE_BLANK = /^[\t\n\v\f\r\u0085\u2028\u2029\p{Zs}]+|[\t\n\v\f\r\u0085\u2028\u2029\p{Zs}]+$/gu;

export function trimBlankAndNewlines(text) {
  return text.replace(EDGE_BLANK, "");
}

const WHITE_SPACE = /\p{White_Space}/u;

/** Swift `Character.isWhitespace` for one UTF-16 unit (every White_Space scalar is in the BMP). */
export function isWhitespaceUnit(unit) {
  return unit !== undefined && WHITE_SPACE.test(unit);
}

/**
 * Applies `transform` to the parts of one line outside backtick code spans. A run of N backticks
 * opens a span that only a run of exactly N backticks closes; an unclosed span runs to the end of
 * the line. Backtick runs and code-span bodies are copied unchanged.
 */
export function processInlineCode(line, transform) {
  if (line.indexOf("`") === -1) {
    return transform(line);
  }
  let result = "";
  let inCode = false;
  let openRun = 0;
  let segmentStart = 0;
  let i = 0;
  while (i < line.length) {
    if (line[i] !== "`") {
      i += 1;
      continue;
    }
    let j = i;
    while (j < line.length && line[j] === "`") {
      j += 1;
    }
    const segment = line.slice(segmentStart, i);
    result += inCode ? segment : transform(segment);
    result += line.slice(i, j);
    if (!inCode) {
      inCode = true;
      openRun = j - i;
    } else if (j - i === openRun) {
      inCode = false;
      openRun = 0;
    }
    i = j;
    segmentStart = i;
  }
  const tail = line.slice(segmentStart);
  return result + (inCode ? tail : transform(tail));
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/**
 * Scans `text` from `from` one character at a time, examining at most `limit` characters, where a character is a
 * grapheme cluster like the Swift `Character` the scientific repairs' scan limits were written for (UTF-16 lengths
 * stay the unit of their admission limits). Stops at the first character for which `visit(character)` is true.
 * Returns `{ index, end, scanned }`: the index of that character or -1, the position scanning stopped at when
 * nothing matched, and how many characters were examined before the match.
 */
export function scanCharacters(text, from, limit, visit) {
  if (text.length - from <= limit) {
    // Fewer code units than the limit remain, so the limit cannot bind: scan code units directly.
    for (let i = from; i < text.length; i += 1) {
      if (visit(text[i])) {
        return { index: i, end: i, scanned: i - from };
      }
    }
    return { index: -1, end: text.length, scanned: text.length - from };
  }
  let scanned = 0;
  let position = from;
  for (const { segment, index } of graphemes.segment(text.slice(from))) {
    if (scanned >= limit) {
      break;
    }
    if (visit(segment)) {
      return { index: from + index, end: from + index, scanned };
    }
    scanned += 1;
    position = from + index + segment.length;
  }
  return { index: -1, end: position, scanned };
}

/** Scans for the `}` closing a group whose body starts at `from`, within `limit` characters. */
export function closingBraceScan(text, from, limit) {
  let depth = 1;
  return scanCharacters(text, from, limit, (character) => {
    if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      return depth === 0;
    }
    return false;
  });
}
