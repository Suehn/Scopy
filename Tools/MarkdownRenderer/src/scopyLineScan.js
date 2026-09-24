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
