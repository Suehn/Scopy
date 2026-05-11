export function preprocessBackslashMath(source) {
  const text = String(source || "");
  const lines = text.split(/(\n)/);
  let inFence = null;
  let mathCount = 0;

  const markdown = lines.map((part) => {
    if (part === "\n") {
      return part;
    }

    const fence = fenceMarker(part);
    if (fence) {
      if (inFence) {
        if (fence.marker === inFence.marker && fence.length >= inFence.length) {
          inFence = null;
        }
      } else {
        inFence = fence;
      }
      return part;
    }

    if (inFence) {
      return part;
    }

    const processed = preprocessInline(part);
    mathCount += processed.mathCount;
    return processed.markdown;
  }).join("");

  return { markdown, mathCount };
}

function fenceMarker(line) {
  const match = /^( {0,3})(`{3,}|~{3,})/.exec(line);
  if (!match) {
    return null;
  }
  const run = match[2];
  return { marker: run[0], length: run.length };
}

function preprocessInline(line) {
  let i = 0;
  let out = "";
  let mathCount = 0;

  while (i < line.length) {
    if (line[i] === "`") {
      const end = findClosingBacktickRun(line, i);
      if (end !== -1) {
        out += line.slice(i, end);
        i = end;
        continue;
      }
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
            out += `$${inner}$`;
          }
          mathCount += 1;
          i = end + 2;
          continue;
        }
      }
    }

    out += line[i];
    i += 1;
  }

  return { markdown: out, mathCount };
}

function findClosingBacktickRun(line, start) {
  let runLength = 0;
  while (line[start + runLength] === "`") {
    runLength += 1;
  }
  const needle = "`".repeat(runLength);
  const close = line.indexOf(needle, start + runLength);
  return close === -1 ? -1 : close + runLength;
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
