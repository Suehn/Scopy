import {
  createFenceTracker,
  fencePrefix,
  isWhitespaceUnit,
  leadingIndentSpaces,
  processInlineCode,
  splitCharacterLines,
  trimBlankAndNewlines as trim
} from "./scopyLineScan.js";

// LaTeX-document-to-Markdown repair for the `latexDocumentLike` and `pdfOCRScientific` profiles
// (policy `allowLatexDocumentNormalize`). It runs before parsing: sectioning commands become
// headings, itemize/enumerate become lists, quote/center/tabular/rule/label are converted or
// dropped. Markdown syntax islands (code, links, images, reference definitions, autolinks, bare
// URLs and file paths) are swapped for placeholders first so the line rewrite never touches them.
// Ported byte-for-byte from the former Swift LaTeXDocumentNormalizer + MarkdownSyntaxProtector;
// test/fixtures/scientific-repairs.json holds the Swift goldens.

export function normalizeLatexDocument(source) {
  if (source === "") {
    return source;
  }
  const islands = protectSyntaxIslands(source);
  const normalized = normalizeDocument(islands.markdown);
  let restored = normalized;
  for (let index = islands.placeholders.length - 1; index >= 0; index -= 1) {
    const [placeholder, original] = islands.placeholders[index];
    restored = restored.split(placeholder).join(original);
  }
  return restored;
}

// MARK: - Syntax islands

function protectSyntaxIslands(source) {
  let salt = 0;
  while (source.includes(`SCOPYMARKDOWNSYNTAX${salt}`)) {
    salt += 1;
  }
  const prefix = `SCOPYMARKDOWNSYNTAX${salt}`;
  const placeholders = [];
  const protect = (original) => {
    const token = `${prefix}${placeholders.length}X`;
    placeholders.push([token, original]);
    return token;
  };

  const output = [];
  let activeFence = null;
  for (const line of splitCharacterLines(source)) {
    const fence = fencePrefix(line);
    if (fence) {
      if (activeFence) {
        activeFence.lines.push(line);
        if (activeFence.marker === fence.marker && fence.count >= activeFence.count) {
          output.push(protect(activeFence.lines.join("\n")));
          activeFence = null;
        }
        continue;
      }
      activeFence = { marker: fence.marker, count: fence.count, lines: [line] };
      continue;
    }
    if (activeFence) {
      activeFence.lines.push(line);
      continue;
    }
    if (isReferenceDefinitionLine(line)) {
      output.push(protect(line));
      continue;
    }
    output.push(protectInlineSyntax(line, protect));
  }
  if (activeFence) {
    output.push(protect(activeFence.lines.join("\n")));
  }
  return { markdown: output.join("\n"), placeholders };
}

function protectInlineSyntax(line, protect) {
  let result = "";
  let i = 0;
  while (i < line.length) {
    const end = backtickSpanEnd(line, i)
      ?? autolinkSpanEnd(line, i)
      ?? linkOrImageSpanEnd(line, i)
      ?? urlSpanEnd(line, i)
      ?? filePathSpanEnd(line, i);
    if (end !== null) {
      result += protect(line.slice(i, end));
      i = end;
      continue;
    }
    result += line[i];
    i += 1;
  }
  return result;
}

function isReferenceDefinitionLine(line) {
  const leading = leadingIndentSpaces(line);
  if (leading > 3) {
    return false;
  }
  const trimmed = line.slice(leading);
  if (trimmed[0] !== "[") {
    return false;
  }
  const close = matchingClose(trimmed, 0, "[", "]");
  return close !== null && close + 1 < trimmed.length && trimmed[close + 1] === ":";
}

function backtickSpanEnd(line, index) {
  if (line[index] !== "`") {
    return null;
  }
  let runEnd = index;
  while (runEnd < line.length && line[runEnd] === "`") {
    runEnd += 1;
  }
  const runCount = runEnd - index;
  let i = runEnd;
  while (i < line.length) {
    if (line[i] !== "`") {
      i += 1;
      continue;
    }
    let closeEnd = i;
    while (closeEnd < line.length && line[closeEnd] === "`") {
      closeEnd += 1;
    }
    if (closeEnd - i === runCount) {
      return closeEnd;
    }
    i = closeEnd;
  }
  return null;
}

function autolinkSpanEnd(line, index) {
  if (line[index] !== "<" || index + 1 >= line.length) {
    return null;
  }
  const head = lowercasedHead(line, index + 1, 8);
  if (!head.startsWith("http://") && !head.startsWith("https://") && !head.startsWith("mailto:")) {
    return null;
  }
  const close = line.indexOf(">", index + 1);
  if (close === -1) {
    return null;
  }
  for (let i = index + 1; i < close; i += 1) {
    if (isWhitespaceUnit(line[i])) {
      return null;
    }
  }
  return close + 1;
}

function linkOrImageSpanEnd(line, index) {
  let labelOpen = index;
  if (line[index] === "!") {
    if (line[index + 1] !== "[") {
      return null;
    }
    labelOpen = index + 1;
  } else if (line[index] !== "[") {
    return null;
  }
  const labelClose = matchingClose(line, labelOpen, "[", "]");
  if (labelClose === null || labelClose + 1 >= line.length) {
    return null;
  }
  const afterLabel = labelClose + 1;
  if (line[afterLabel] === "(") {
    const destinationClose = matchingClose(line, afterLabel, "(", ")");
    if (destinationClose !== null) {
      return destinationClose + 1;
    }
  }
  if (line[afterLabel] === "[") {
    const referenceClose = matchingClose(line, afterLabel, "[", "]");
    if (referenceClose !== null) {
      return referenceClose + 1;
    }
  }
  return null;
}

function urlSpanEnd(line, index) {
  if (line[index] !== "h" && line[index] !== "H") {
    return null;
  }
  const head = lowercasedHead(line, index, 8);
  return head.startsWith("http://") || head.startsWith("https://") ? boundaryEnd(line, index) : null;
}

const FILE_PATH_PREFIXES = ["/Users/", "/Volumes/", "~/", "./", "../"];

function filePathSpanEnd(line, index) {
  const isPath = FILE_PATH_PREFIXES.some((prefix) => line.startsWith(prefix, index))
    || ((line[index] === "f" || line[index] === "F") && lowercasedHead(line, index, 7).startsWith("file://"));
  return isPath ? boundaryEnd(line, index) : null;
}

function lowercasedHead(line, index, length) {
  return line.slice(index, index + length).toLowerCase();
}

function boundaryEnd(line, index) {
  let i = index;
  while (i < line.length && !isWhitespaceUnit(line[i])) {
    i += 1;
  }
  return i;
}

// A line never contains a bare "\n" (lines end there; a "\n" inside a line belongs to "\r\n"),
// so only escapes and nesting matter here.
function matchingClose(text, openIndex, open, close) {
  if (text[openIndex] !== open) {
    return null;
  }
  let depth = 1;
  let i = openIndex + 1;
  while (i < text.length) {
    const ch = text[i];
    if (ch === "\\") {
      i = Math.min(i + 2, text.length);
      continue;
    }
    if (ch === open) {
      depth += 1;
    } else if (ch === close) {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
    i += 1;
  }
  return null;
}

// MARK: - Document lines

function normalizeDocument(text) {
  if (text === "") {
    return text;
  }
  const lines = text
    .replace(/\r\n/g, "\n")
    .replace(/[\r\u2028\u2029]/g, "\n")
    .split("\n");
  const output = [];
  const fences = createFenceTracker();
  const listStack = [];
  let inQuoteBlock = false;
  let tabularLines = null;
  const emit = (line) => output.push(inQuoteBlock && trim(line) !== "" ? `> ${line}` : line);

  for (let line of lines) {
    if (fences.skip(line)) {
      output.push(line);
      continue;
    }
    if (tabularLines) {
      if (isEndEnvironmentLine(line, "tabular")) {
        convertTabularToMarkdownTable(tabularLines).forEach(emit);
        tabularLines = null;
      } else {
        tabularLines.push(line);
      }
      continue;
    }

    const trimmedLine = trim(line);
    if (trimmedLine.startsWith("\\label{") && trimmedLine.endsWith("}") && !trimmedLine.startsWith("`")) {
      continue;
    }
    line = processInlineCode(line, removeInlineLabels);

    if (isBeginEnvironmentLine(line, "quote")) {
      inQuoteBlock = true;
      continue;
    }
    if (isEndEnvironmentLine(line, "quote")) {
      inQuoteBlock = false;
      continue;
    }
    if (isBeginEnvironmentLine(line, "center") || isEndEnvironmentLine(line, "center")) {
      continue;
    }
    if (trim(line).startsWith("\\begin{tabular}") || trim(line).startsWith("\\begin{tabular*}")) {
      tabularLines = [];
      continue;
    }
    if (isBeginEnvironmentLine(line, "itemize")) {
      listStack.push("bullet");
      continue;
    }
    if (isEndEnvironmentLine(line, "itemize")) {
      if (listStack[listStack.length - 1] === "bullet") {
        listStack.pop();
      }
      continue;
    }
    if (isBeginEnvironmentLine(line, "enumerate")) {
      listStack.push("ordered");
      continue;
    }
    if (isEndEnvironmentLine(line, "enumerate")) {
      if (listStack[listStack.length - 1] === "ordered") {
        listStack.pop();
      }
      continue;
    }

    emit(
      convertHeadingLine(line, SECTION_HEADINGS)
        ?? convertHeadingLine(line, PARAGRAPH_HEADINGS)
        ?? convertItemLine(line, listStack)
        ?? convertHorizontalRuleLine(line)
        ?? line
    );
  }
  return output.join("\n");
}

const SECTION_HEADINGS = [["section", "#"], ["subsection", "##"], ["subsubsection", "###"]];
const PARAGRAPH_HEADINGS = [["paragraph", "####"], ["subparagraph", "#####"]];

function convertHeadingLine(line, mappings) {
  const trimmed = trim(line);
  if (!trimmed.startsWith("\\")) {
    return null;
  }
  for (const [command, prefix] of mappings) {
    for (const star of ["", "*"]) {
      const head = `\\${command}${star}{`;
      if (!trimmed.startsWith(head) || !trimmed.endsWith("}")) {
        continue;
      }
      const inner = trimmed.slice(head.length, -1);
      return inner === "" ? null : `${prefix} ${inner}`;
    }
  }
  return null;
}

function convertItemLine(line, listStack) {
  const trimmed = trim(line);
  if (!trimmed.startsWith("\\item")) {
    return null;
  }
  const kind = listStack[listStack.length - 1] ?? "bullet";
  const indent = "  ".repeat(Math.max(0, listStack.length - 1));
  const rest = trim(stripOptionalBracketPrefix(trimmed.slice("\\item".length)));
  return `${indent}${kind === "ordered" ? "1. " : "- "}${rest}`;
}

function stripOptionalBracketPrefix(text) {
  const trimmed = trim(text);
  if (!trimmed.startsWith("[")) {
    return text;
  }
  let depth = 0;
  for (let i = 0; i < trimmed.length; i += 1) {
    if (trimmed[i] === "[") {
      depth += 1;
    }
    if (trimmed[i] === "]") {
      depth -= 1;
      if (depth === 0) {
        return trimmed.slice(i + 1);
      }
    }
  }
  return text;
}

function isBeginEnvironmentLine(line, name) {
  const trimmed = trim(line);
  const head = `\\begin{${name}}`;
  return trimmed === head || trimmed.startsWith(`${head}[`);
}

function isEndEnvironmentLine(line, name) {
  return trim(line) === `\\end{${name}}`;
}

function removeInlineLabels(segment) {
  let out = segment;
  let start = out.indexOf("\\label{");
  while (start !== -1) {
    let i = start + "\\label{".length;
    let depth = 1;
    let scanned = 0;
    while (i < out.length && scanned < 4000) {
      const ch = out[i];
      if (ch === "{") {
        depth += 1;
      }
      if (ch === "}") {
        depth -= 1;
        if (depth === 0) {
          i += 1;
          break;
        }
      }
      i += 1;
      scanned += 1;
    }
    out = out.slice(0, start) + out.slice(i);
    start = out.indexOf("\\label{");
  }
  return out;
}

function convertHorizontalRuleLine(line) {
  const trimmed = trim(line);
  for (const width of ["\\linewidth", "\\textwidth"]) {
    const rule = `\\rule{${width}}`;
    if (trimmed.startsWith(`\\noindent${rule}`) || trimmed.startsWith(rule)) {
      return "---";
    }
  }
  return null;
}

// \begin{tabular}{..} ... \end{tabular} with `&` cells, `\\` row ends and \hline rules becomes a
// pipe table whose first row is the header; short rows are padded, long rows fold into the last cell.
function convertTabularToMarkdownTable(lines) {
  const rows = [];
  const flushRow = (row) => {
    const trimmed = trim(row);
    if (trimmed !== "") {
      rows.push(trimmed);
    }
  };
  let current = "";
  for (const line of lines) {
    const trimmed = trim(line);
    if (trimmed === "" || trimmed === "\\hline" || trimmed === "\\hline{}" || trimmed.startsWith("\\hline%")) {
      continue;
    }
    current += current === "" ? trimmed : ` ${trimmed}`;
    for (let rowEnd = current.indexOf("\\\\"); rowEnd !== -1; rowEnd = current.indexOf("\\\\")) {
      flushRow(current.slice(0, rowEnd));
      current = trim(current.slice(rowEnd + 2));
    }
  }
  flushRow(current);
  if (rows.length === 0) {
    return [];
  }
  const columnCount = splitTabularCells(rows[0]).length;
  const tableRow = (cells) => `| ${cells.join(" | ")} |`;
  const out = [tableRow(splitTabularCells(rows[0])), tableRow(Array(columnCount).fill("---"))];
  for (const row of rows.slice(1)) {
    let cells = splitTabularCells(row);
    if (cells.length < columnCount) {
      cells = cells.concat(Array(columnCount - cells.length).fill(""));
    } else if (cells.length > columnCount) {
      cells = cells.slice(0, columnCount - 1).concat(cells.slice(columnCount - 1).join(" "));
    }
    out.push(tableRow(cells));
  }
  return out;
}

function splitTabularCells(row) {
  const cells = [];
  let current = "";
  let previousWasBackslash = false;
  for (const ch of row) {
    if (ch === "&" && !previousWasBackslash) {
      cells.push(trim(current));
      current = "";
      previousWasBackslash = false;
      continue;
    }
    current += ch;
    previousWasBackslash = ch === "\\";
  }
  const last = trim(current);
  if (last !== "" || cells.length > 0) {
    cells.push(last);
  }
  return cells;
}
