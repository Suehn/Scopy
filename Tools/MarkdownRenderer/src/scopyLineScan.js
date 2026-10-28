// Shared lexical boundaries for source repairs. Container nesting and paragraph ownership
// remain the Markdown parser's responsibility; these helpers inspect physical source lines.

const FENCE_LINE = /^ {0,3}(`{3,}|~{3,})([^\r\n]*)(?:\r?\n|\r|$)/;

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
 * closes only on a marker of the same character with at least the opening run length and no
 * trailing content. A backtick opener cannot contain backticks in its info string.
 */
export function createFenceTracker() {
  let active = null;
  return {
    get isOpen() { return active !== null; },
    skip(line) {
      const fence = FENCE_LINE.exec(line);
      if (active) {
        if (fence && fence[1][0] === active[0] && fence[1].length >= active.length && /^[\t ]*$/.test(fence[2])) {
          active = null;
        }
        return true;
      }
      if (!fence || (fence[1][0] === "`" && fence[2].includes("`"))) return false;
      active = fence[1];
      return true;
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
 * Finds paired backtick spans in source order. Only a run of exactly the opening length closes
 * a span. Escapes affect openers, but have no meaning inside code. Unmatched runs remain text.
 * Index each run's next equal-length run once, so many unmatched runs never rescan the suffix.
 */
export function createInlineCodeScanner(line) {
  const runs = [];
  for (const match of line.matchAll(/`+/g)) {
    const start = match.index;
    let escapes = 0;
    for (let i = start - 1; i >= 0 && line[i] === "\\"; i -= 1) escapes += 1;
    runs.push({ start, end: start + match[0].length, escaped: escapes % 2 });
  }
  const next = new Map();
  for (let i = runs.length - 1; i >= 0; i -= 1) {
    const run = runs[i];
    run.close = next.get(run.end - run.start - run.escaped);
    next.set(run.end - run.start, i);
  }
  let index = 0;
  return {
    // Callers advance `from` monotonically. A link/URL may own an earlier backtick, so only
    // the caller decides where the next candidate can start; finding a span does not consume its body.
    next(from) {
      while (index < runs.length) {
        const open = runs[index++];
        if (open.start + open.escaped < from || open.close === undefined) continue;
        const close = runs[open.close];
        return {
          start: open.start + open.escaped,
          end: close.end,
          bodyStart: open.end,
          bodyEnd: close.start,
          markerLength: open.end - open.start - open.escaped
        };
      }
      return null;
    }
  };
}

/** Applies `transform` outside paired code spans within one source line. */
export function processInlineCode(line, transform) {
  let result = "";
  let from = 0;
  const code = createInlineCodeScanner(line);
  for (let span = code.next(from); span; span = code.next(from)) {
    result += transform(line.slice(from, span.start));
    result += line.slice(span.start, span.end);
    from = span.end;
  }
  return result + transform(line.slice(from));
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
