import { createFenceTracker, createInlineCodeScanner } from "./scopyLineScan.js";

export function preprocessBackslashMath(source) {
  const text = String(source || "");
  if (!/\\[()[\]]/.test(text)) {
    return { markdown: text, mathCount: 0 };
  }
  const lines = text.split("\n");
  const fences = createFenceTracker();
  let inDisplayBlock = false;
  let displayOpenLine = "";
  let displayLines = [];
  let mathCount = 0;
  const output = [];

  for (const line of lines) {
    if (fences.skip(line)) {
      output.push(line);
      continue;
    }

    if (line.trim() === "\\[") {
      inDisplayBlock = true;
      displayOpenLine = line;
      displayLines = [];
      continue;
    }

    if (inDisplayBlock) {
      if (line.trim() === "\\]") {
        if (displayLines.join("\n").trim()) {
          output.push("$$", ...displayLines, "$$");
          mathCount += 1;
        } else {
          output.push(escapeLiteralDelimiter(displayOpenLine, "["), escapeLiteralDelimiter(line, "]"));
        }
        inDisplayBlock = false;
        displayOpenLine = "";
        displayLines = [];
      } else {
        displayLines.push(line);
      }
      continue;
    }

    const processed = preprocessInline(line);
    mathCount += processed.mathCount;
    output.push(processed.markdown);
  }

  if (inDisplayBlock) {
    output.push(escapeLiteralDelimiter(displayOpenLine, "["), ...displayLines);
  }

  return { markdown: output.join("\n"), mathCount };
}

function preprocessInline(line) {
  let i = 0;
  let out = "";
  let mathCount = 0;
  const code = createInlineCodeScanner(line);
  let span = code.next(0);

  while (i < line.length) {
    if (span && span.start < i) span = code.next(i);
    if (span?.start === i) {
      out += line.slice(i, span.end);
      i = span.end;
      continue;
    }

    if (line[i] === "\\" && line[i + 1] === "\\") {
      out += "\\\\";
      i += 2;
      continue;
    }

    const linkEnd = findMarkdownLinkEnd(line, i);
    if (linkEnd !== -1) {
      out += line.slice(i, linkEnd);
      i = linkEnd;
      continue;
    }

    if (line[i] === "<") {
      const end = line.indexOf(">", i + 1);
      if (end !== -1) {
        out += line.slice(i, end + 1);
        i = end + 1;
        continue;
      }
    }

    if (line[i] === "\\" && (line[i + 1] === "(" || line[i + 1] === "[")) {
      const display = line[i + 1] === "[";
      const close = display ? "\\]" : "\\)";
      const end = line.indexOf(close, i + 2);
      if (end !== -1) {
        const inner = line.slice(i + 2, end);
        if (inner.trim()) {
          if (display && line.slice(0, i).trim() === "" && line.slice(end + 2).trim() === "") {
            out += `$$\n${inner}\n$$`;
          } else {
            out += `$$${inner}$$`;
          }
          mathCount += 1;
          i = end + 2;
          continue;
        }
      }
      out += `\\\\${line[i + 1]}`;
      i += 2;
      continue;
    }

    if (line[i] === "\\" && (line[i + 1] === ")" || line[i + 1] === "]")) {
      out += `\\\\${line[i + 1]}`;
      i += 2;
      continue;
    }

    out += line[i];
    i += 1;
  }

  return { markdown: out, mathCount };
}

function escapeLiteralDelimiter(line, delimiter) {
  const source = String(line || "");
  const index = source.indexOf(`\\${delimiter}`);
  if (index === -1) {
    return source;
  }
  return `${source.slice(0, index)}\\\\${delimiter}${source.slice(index + 2)}`;
}

function findMarkdownLinkEnd(line, start) {
  const imageOffset = line[start] === "!" && line[start + 1] === "[" ? 1 : 0;
  if (line[start + imageOffset] !== "[") {
    return -1;
  }

  const labelEnd = findBalancedSquareEnd(line, start + imageOffset);
  if (labelEnd === -1) {
    return -1;
  }

  const next = labelEnd + 1;
  if (line[next] === "(") {
    const destinationEnd = findBalancedParenEnd(line, next);
    return destinationEnd === -1 ? -1 : destinationEnd + 1;
  }
  if (line[next] === "[") {
    const referenceEnd = findBalancedSquareEnd(line, next);
    return referenceEnd === -1 ? -1 : referenceEnd + 1;
  }
  return -1;
}

function findBalancedSquareEnd(line, start) {
  let depth = 0;
  for (let i = start; i < line.length; i += 1) {
    if (line[i] === "\\" && i + 1 < line.length) {
      i += 1;
      continue;
    }
    if (line[i] === "[") {
      depth += 1;
    } else if (line[i] === "]") {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

function findBalancedParenEnd(line, start) {
  let depth = 0;
  for (let i = start; i < line.length; i += 1) {
    if (line[i] === "\\" && i + 1 < line.length) {
      i += 1;
      continue;
    }
    if (line[i] === "(") {
      depth += 1;
    } else if (line[i] === ")") {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}
