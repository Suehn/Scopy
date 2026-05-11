export function preprocessDollarMathGuards(source) {
  const text = String(source || "");
  const lines = text.split("\n");
  const output = [];
  let inFence = null;

  for (const line of lines) {
    const fence = fenceMarker(line);
    if (fence) {
      if (inFence) {
        if (fence.marker === inFence.marker && fence.length >= inFence.length) {
          inFence = null;
        }
      } else {
        inFence = fence;
      }
      output.push(line);
      continue;
    }

    output.push(inFence ? line : escapeDollarGuardsInline(line));
  }

  return output.join("\n");
}

function escapeDollarGuardsInline(line) {
  let i = 0;
  let out = "";
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

    const urlEnd = findBareURLEnd(line, i);
    if (urlEnd !== -1) {
      out += line.slice(i, urlEnd);
      i = urlEnd;
      continue;
    }

    if (line[i] === "$" && shouldEscapeDollar(line, i)) {
      out += "\\$";
      i += 1;
      continue;
    }

    out += line[i];
    i += 1;
  }
  return out;
}

function shouldEscapeDollar(line, index) {
  if (index > 0 && line[index - 1] === "\\") {
    return false;
  }
  const next = line[index + 1] || "";
  const next2 = line[index + 2] || "";
  if (/\d/.test(next)) {
    return true;
  }
  if (/\s/.test(next) && /\d/.test(next2)) {
    return true;
  }
  if (/[A-Za-z_]/.test(next)) {
    return !hasLikelyClosingMathDollar(line, index);
  }
  return false;
}

function hasLikelyClosingMathDollar(line, index) {
  for (let i = index + 1; i < line.length; i += 1) {
    if (/\s/.test(line[i])) {
      return false;
    }
    if (line[i] === "$" && line[i - 1] !== "\\") {
      const inner = line.slice(index + 1, i);
      if (!inner.trim() || /[/:]/.test(inner)) {
        return false;
      }
      return true;
    }
  }
  return false;
}

function findBareURLEnd(line, start) {
  if (!/^https?:\/\//i.test(line.slice(start))) {
    return -1;
  }
  let i = start;
  while (i < line.length && !/\s/.test(line[i])) {
    i += 1;
  }
  return i;
}

function fenceMarker(line) {
  const match = /^( {0,3})(`{3,}|~{3,})/.exec(line);
  if (!match) {
    return null;
  }
  const run = match[2];
  return { marker: run[0], length: run.length };
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

  const labelEnd = findBalancedEnd(line, start + imageOffset, "[", "]");
  if (labelEnd === -1) {
    return -1;
  }

  const next = labelEnd + 1;
  if (line[next] === "(") {
    const destinationEnd = findBalancedEnd(line, next, "(", ")");
    return destinationEnd === -1 ? -1 : destinationEnd + 1;
  }
  if (line[next] === "[") {
    const referenceEnd = findBalancedEnd(line, next, "[", "]");
    return referenceEnd === -1 ? -1 : referenceEnd + 1;
  }
  return -1;
}

function findBalancedEnd(line, start, open, close) {
  let depth = 0;
  for (let i = start; i < line.length; i += 1) {
    if (line[i] === "\\" && i + 1 < line.length) {
      i += 1;
      continue;
    }
    if (line[i] === open) {
      depth += 1;
    } else if (line[i] === close) {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}
