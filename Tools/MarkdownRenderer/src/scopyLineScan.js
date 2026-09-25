// One definition of "fence line" and "indentation" for every source-level rewrite that runs
// before parsing and must leave code alone (heading repair, table code-span pipes, backslash
// math). The rules mirror the Swift `MarkdownCodeSkipper` they replaced: any indentation may
// precede a fence, and only spaces and tabs (Unicode Zs plus U+0009) count as leading blank.

const LEADING_BLANK = /^[\t\p{Zs}]+/u;

/**
 * `{ marker, count }` when `line` is a fence marker line: optional leading blank, then three or
 * more of the same "`" or "~" character. `null` otherwise.
 */
export function fencePrefix(line) {
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
