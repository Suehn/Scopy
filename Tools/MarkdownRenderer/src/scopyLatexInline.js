import {
  closingBraceScan,
  createFenceTracker,
  isWhitespaceUnit,
  leadingIndentSpaces,
  processInlineCode,
  splitCharacterLines,
  trimBlankAndNewlines as trim
} from "./scopyLineScan.js";

// Inline LaTeX repair for the scientific profiles (policy `allowLatexInlineTextNormalize`), run
// before parsing. Math regions ($..$, $$..$$, \(..\), \[..\], supported environments, including
// multi-line $$ and \begin..\end blocks) are swapped for placeholders while \textbf/\emph/\textit
// outside math become Markdown emphasis; each math region is itself normalized on the way
// (JSON-style `\\cmd`, `_` inside \text{}, the first \label{}, `={..|..}` set braces, and `&`/`\`
// inline math upgraded to an aligned block). PDF/Word `$` artifacts are repaired first.
// Ported byte-for-byte from the former Swift MathProtector + LaTeXInlineTextNormalizer;
// test/fixtures/scientific-repairs.json holds the Swift goldens.

const MAX_INPUT_LENGTH = 200_000;
const MAX_INLINE_MATH_LENGTH = 2_000;
const MAX_BLOCK_MATH_LENGTH = 8_000;

const ENVIRONMENT_NAMES = [
  "equation", "equation*",
  "align", "align*",
  "alignat", "alignat*",
  "alignedat",
  "aligned",
  "cases",
  "gather", "gather*",
  "multline", "multline*",
  "split",
  "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "array"
];
const ENVIRONMENTS = new Set(ENVIRONMENT_NAMES);

const PLACEHOLDER_MARK = "SCOPYMATHPLACEHOLDER";

export function normalizeLatexInline(source) {
  const { markdown, placeholders } = protectMath(source);
  let out = normalizeInlineText(markdown);
  // Outer segments first, so an inner placeholder an outer original still contains is restored next.
  for (let index = placeholders.length - 1; index >= 0; index -= 1) {
    const [placeholder, original] = placeholders[index];
    out = out.split(placeholder).join(original);
  }
  return out;
}

// MARK: - \textbf, \emph, \textit outside code and math

function normalizeInlineText(text) {
  if (!text.includes("\\textbf{") && !text.includes("\\emph{") && !text.includes("\\textit{")) {
    return text;
  }
  const fences = createFenceTracker();
  return splitCharacterLines(text)
    .map((line) => (fences.skip(line) ? line : processInlineCode(line, normalizeTextCommands)))
    .join("\n");
}

function normalizeTextCommands(segment) {
  let out = replaceCommandWithBracedArg(segment, "\\textbf{", (inner) => `**${inner}**`);
  out = replaceCommandWithBracedArg(out, "\\emph{", (inner) => `*${inner}*`);
  return replaceCommandWithBracedArg(out, "\\textit{", (inner) => `*${inner}*`);
}

function replaceCommandWithBracedArg(text, head, wrap) {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const start = text.indexOf(head, i);
    if (start === -1) {
      return out + text.slice(i);
    }
    out += text.slice(i, start);
    const close = closingBrace(text, start + head.length, 10_000);
    if (close === -1) {
      return out + text.slice(start);
    }
    out += wrap(text.slice(start + head.length, close));
    i = close + 1;
  }
  return out;
}

/** Index of the `}` closing a group whose body starts at `from`, within `limit` characters, or -1. */
function closingBrace(text, from, limit) {
  return closingBraceScan(text, from, limit).index;
}

// MARK: - Math protection

function protectMath(markdown) {
  if (markdown.length > MAX_INPUT_LENGTH || (!markdown.includes("$") && !markdown.includes("\\"))) {
    return { markdown, placeholders: [] };
  }
  // Same length as the Swift UUID-salted prefix, so length limits see identical text.
  let salt = 0;
  while (markdown.includes(PLACEHOLDER_MARK + String(salt).padStart(32, "0"))) {
    salt += 1;
  }
  const prefix = PLACEHOLDER_MARK + String(salt).padStart(32, "0");
  const placeholders = [];
  const protect = (original) => {
    const token = `${prefix}${placeholders.length}X`;
    placeholders.push([token, original]);
    return token;
  };

  const output = [];
  const fences = createFenceTracker();
  // One pending block at a time: a multi-line `$$` block or a supported environment.
  let dollarBlock = null;
  let environment = null;

  for (const line of splitCharacterLines(markdown)) {
    if (fences.skip(line)) {
      output.push(line);
      continue;
    }

    const beginName = environment ? null : environmentBeginName(line);
    if (beginName) {
      environment = { name: beginName, indent: Math.min(3, leadingIndentSpaces(line)), lines: [line], length: line.length };
      if (line.includes(`\\end{${beginName}}`)) {
        output.push(" ".repeat(environment.indent) + protect(normalizeMathSegment(line)));
        environment = null;
      }
      continue;
    }
    if (environment) {
      if (environment.length + line.length > MAX_BLOCK_MATH_LENGTH * 8) {
        output.push(...environment.lines);
        environment = null;
      } else {
        environment.lines.push(line);
        environment.length += line.length;
        if (line.includes(`\\end{${environment.name}}`)) {
          output.push(" ".repeat(environment.indent) + protect(normalizeMathSegment(environment.lines.join("\n"))));
          environment = null;
        }
        continue;
      }
    }

    if (trim(line) === "$$") {
      if (dollarBlock) {
        dollarBlock.lines.push(line);
        output.push(" ".repeat(dollarBlock.indent) + protect(normalizeMathSegment(dollarBlock.lines.join("\n"))));
        dollarBlock = null;
      } else {
        dollarBlock = { indent: Math.min(3, leadingIndentSpaces(line)), lines: [line], length: line.length };
      }
      continue;
    }
    if (dollarBlock) {
      if (dollarBlock.length + line.length > MAX_BLOCK_MATH_LENGTH * 4) {
        output.push(...dollarBlock.lines);
        dollarBlock = null;
      } else {
        dollarBlock.lines.push(line);
        dollarBlock.length += line.length;
        continue;
      }
    }

    output.push(processInlineCode(line, (segment) => protectMathInSegment(segment, protect)));
  }
  if (dollarBlock) {
    output.push(...dollarBlock.lines);
  }
  if (environment) {
    output.push(...environment.lines);
  }
  return { markdown: output.join("\n"), placeholders: resolveNestedPlaceholders(placeholders) };
}

function environmentBeginName(line) {
  const trimmed = trim(line);
  if (!trimmed.startsWith("\\begin{")) {
    return null;
  }
  const close = trimmed.indexOf("}");
  const name = trimmed.slice("\\begin{".length, close);
  return close !== -1 && ENVIRONMENTS.has(name) ? name : null;
}

// Environment protection runs before `$` protection, so `$..\begin{cases}..\end{cases}..$` stores
// an outer original that contains an inner placeholder; expand originals to be self-contained.
function resolveNestedPlaceholders(placeholders) {
  if (placeholders.length < 2) {
    return placeholders;
  }
  const resolved = [];
  for (const [placeholder, original] of placeholders) {
    let expanded = original;
    if (expanded.includes(PLACEHOLDER_MARK)) {
      for (const [inner, innerOriginal] of resolved) {
        expanded = expanded.split(inner).join(innerOriginal);
      }
    }
    resolved.push([placeholder, expanded]);
  }
  if (resolved.some(([, original]) => original.includes(PLACEHOLDER_MARK))) {
    for (const entry of resolved) {
      for (const [other, otherOriginal] of resolved) {
        if (other !== entry[0]) {
          entry[1] = entry[1].split(other).join(otherOriginal);
        }
      }
    }
  }
  return resolved;
}

function protectMathInSegment(text, protect) {
  if (!text.includes("$") && !text.includes("\\")) {
    return text;
  }
  let out = removeStrayDollarsBeforeTeXCommands(disambiguateDoubleDollars(text));
  for (const name of ENVIRONMENT_NAMES) {
    out = protectDelimited(out, `\\begin{${name}}`, `\\end{${name}}`, MAX_BLOCK_MATH_LENGTH, protect);
  }
  out = protectDelimited(out, "\\(", "\\)", MAX_INLINE_MATH_LENGTH, protect);
  out = protectDelimited(out, "\\[", "\\]", MAX_BLOCK_MATH_LENGTH, protect);
  out = protectDollarMath(out, true, MAX_BLOCK_MATH_LENGTH, protect);
  return protectDollarMath(out, false, MAX_INLINE_MATH_LENGTH, protect);
}

const SPACING_COMMANDS = ["\\quad", "\\qquad", "\\,", "\\;", "\\:", "\\!"];

// PDF/Word extraction may insert a stray `$` before a TeX command inside one math run:
// `$a \quad $\mathbf{b}$` means `$a \quad \mathbf{b}$`.
function removeStrayDollarsBeforeTeXCommands(text) {
  if (!text.includes("$") || !text.includes("\\")) {
    return text;
  }
  let out = "";
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === "$" && text[i + 1] === "\\") {
      let j = i;
      while (j > 0 && isWhitespaceUnit(text[j - 1])) {
        j -= 1;
      }
      if (SPACING_COMMANDS.some((command) => text.endsWith(command, j))) {
        continue;
      }
    }
    out += text[i];
  }
  return out;
}

// Adjacent inline math from PDF/Word extraction produces `$$` that is not a display delimiter:
// `$\mathbf{b}$$\in$` means `$\mathbf{b}$ $\in$`, and `$x$$,` means `$x$,`.
function disambiguateDoubleDollars(text) {
  if (!text.includes("$$")) {
    return text;
  }
  let out = "";
  let i = 0;
  while (i < text.length) {
    if (text[i] === "$" && text[i + 1] === "$") {
      const previous = text[i - 1];
      const next = text[i + 2];
      const previousIsBoundary = previous === undefined || isWhitespaceUnit(previous);
      const nextIsBoundary = next === undefined || isWhitespaceUnit(next);
      if (previousIsBoundary || nextIsBoundary) {
        out += "$$";
      } else {
        out += PUNCTUATION.has(next) ? "$" : "$ $";
      }
      i += 2;
      continue;
    }
    out += text[i];
    i += 1;
  }
  return out;
}

const PUNCTUATION = new Set([",", ".", ";", ":", "?", "!", ")", "]", "}", "，", "。", "；", "：", "？", "！", "）", "】", "、"]);

function protectDelimited(text, left, right, maxInnerLength, protect) {
  if (!text.includes(left) || !text.includes(right)) {
    return text;
  }
  let result = "";
  let i = 0;
  while (i < text.length) {
    const start = text.indexOf(left, i);
    if (start === -1) {
      return result + text.slice(i);
    }
    result += text.slice(i, start);
    const innerStart = start + left.length;
    const innerEnd = text.indexOf(right, innerStart);
    if (innerEnd === -1) {
      return result + text.slice(start);
    }
    const end = innerEnd + right.length;
    const innerLength = innerEnd - innerStart;
    result += innerLength === 0 || innerLength > maxInnerLength
      ? text.slice(start, end)
      : protect(normalizeMathSegment(text.slice(start, end)));
    i = end;
  }
  return result;
}

function protectDollarMath(text, isBlock, maxInnerLength, protect) {
  const delimiter = isBlock ? "$$" : "$";
  if (!text.includes(delimiter)) {
    return text;
  }
  let result = "";
  let i = 0;
  while (i < text.length) {
    const start = findDollarDelimiter(text, delimiter, i, isBlock);
    if (start === -1) {
      return result + text.slice(i);
    }
    result += text.slice(i, start);
    const innerStart = start + delimiter.length;
    const innerEnd = findDollarDelimiter(text, delimiter, innerStart, isBlock);
    if (innerEnd === -1) {
      return result + text.slice(start);
    }
    const inner = text.slice(innerStart, innerEnd);
    // A bare "\n" never occurs inside a line; "\r\n" is one character and does not count.
    if ((!isBlock && hasBareNewline(inner)) || inner.length === 0 || inner.length > maxInnerLength) {
      result += text[start];
      i = start + 1;
      continue;
    }
    const end = innerEnd + delimiter.length;
    let original = text.slice(start, end);
    // PDF/Word extraction may drop \begin{aligned} but keep the `&` alignment points.
    if (!isBlock && inner.includes("&") && inner.includes("\\") && !inner.includes("\\begin{")) {
      original = `$$\\begin{aligned} ${inner} \\end{aligned}$$`;
    }
    result += protect(normalizeMathSegment(original));
    i = end;
  }
  return result;
}

function hasBareNewline(text) {
  for (let i = text.indexOf("\n"); i !== -1; i = text.indexOf("\n", i + 1)) {
    if (i === 0 || text[i - 1] !== "\r") {
      return true;
    }
  }
  return false;
}

function findDollarDelimiter(text, delimiter, from, isBlock) {
  for (let start = text.indexOf(delimiter, from); start !== -1; start = text.indexOf(delimiter, start + delimiter.length)) {
    const previous = text[start - 1];
    if (previous === "\\") {
      continue;
    }
    if (isBlock) {
      // Adjacent `$..$$..$` artifacts are not display delimiters.
      const next = text[start + delimiter.length];
      const previousIsBoundary = previous === undefined || isWhitespaceUnit(previous) || PUNCTUATION.has(previous);
      const nextIsBoundary = next === undefined || isWhitespaceUnit(next) || PUNCTUATION.has(next);
      if (!previousIsBoundary && !nextIsBoundary) {
        continue;
      }
    }
    return start;
  }
  return -1;
}

// MARK: - Math segment normalization

function normalizeMathSegment(segment) {
  let out = normalizeEscapedTeXCommands(segment);
  out = escapeUnderscoresInsideText(out);
  out = removeFirstLabel(out);
  return normalizeSetBraces(out);
}

// Text copied from JSON or code often has `\\command` for `\command`.
function normalizeEscapedTeXCommands(text) {
  if (!text.includes("\\\\")) {
    return text;
  }
  let out = "";
  let i = 0;
  while (i < text.length) {
    if (text[i] !== "\\") {
      out += text[i];
      i += 1;
      continue;
    }
    let j = i;
    while (j < text.length && text[j] === "\\" && j - i < 8) {
      j += 1;
    }
    const run = j - i;
    out += run >= 2 && j < text.length && ALPHABETIC.test(String.fromCodePoint(text.codePointAt(j))) ? "\\" : "\\".repeat(run);
    i = j;
  }
  return out;
}

const ALPHABETIC = /^\p{Alphabetic}$/u;

// KaTeX follows LaTeX: `_` in text mode must be escaped (`\text{drop_last}`).
function escapeUnderscoresInsideText(text) {
  if (!text.includes("\\text{") || !text.includes("_")) {
    return text;
  }
  // One character budget for the whole segment, as in the Swift original.
  const limit = MAX_BLOCK_MATH_LENGTH * 8;
  let out = "";
  let i = 0;
  let scanned = 0;
  while (i < text.length && scanned < limit) {
    const start = text.indexOf("\\text{", i);
    if (start === -1) {
      return out + text.slice(i);
    }
    out += text.slice(i, start) + "\\text{";
    const bodyStart = start + "\\text{".length;
    const close = closingBraceScan(text, bodyStart, limit - scanned);
    if (close.index === -1) {
      return out + text.slice(bodyStart);
    }
    out += escapeUnescapedUnderscores(text.slice(bodyStart, close.index)) + "}";
    scanned += close.scanned + 1;
    i = close.index + 1;
  }
  return out;
}

function escapeUnescapedUnderscores(text) {
  let out = "";
  let previousWasBackslash = false;
  for (const ch of text) {
    if (ch === "_" && !previousWasBackslash) {
      out += "\\";
    }
    out += ch;
    previousWasBackslash = ch === "\\";
  }
  return out;
}

// Only the first `\label{..}` goes, with the blanks before it and the blanks plus one newline after.
function removeFirstLabel(text) {
  const start = text.indexOf("\\label");
  const braceOpen = start + "\\label".length;
  if (start === -1 || text[braceOpen] !== "{") {
    return text;
  }
  const close = closingBrace(text, braceOpen + 1, MAX_BLOCK_MATH_LENGTH);
  if (close === -1) {
    return text;
  }
  let left = start;
  while (left > 0 && (text[left - 1] === " " || text[left - 1] === "\t")) {
    left -= 1;
  }
  let right = close + 1;
  while (text[right] === " " || text[right] === "\t") {
    right += 1;
  }
  if (text[right] === "\n") {
    right += 1;
  }
  return text.slice(0, left) + text.slice(right);
}

// `={..}` holding `\mid` or `|` is set-builder notation with literal braces: `=\{..\}`.
function normalizeSetBraces(text) {
  if (!text.includes("={")) {
    return text;
  }
  let out = "";
  let i = 0;
  while (i < text.length) {
    if (text[i] === "=" && text[i + 1] === "{") {
      const close = closingBrace(text, i + 2, MAX_BLOCK_MATH_LENGTH);
      if (close !== -1) {
        const inner = text.slice(i + 2, close);
        if ((inner.includes("\\mid") || inner.includes("|")) && !inner.includes("\\{") && !inner.includes("\\}")) {
          out += `=\\{${inner}\\}`;
          i = close + 1;
          continue;
        }
      }
    }
    out += text[i];
    i += 1;
  }
  return out;
}
