import rehypeHighlight from "rehype-highlight";
import rehypeKatex from "rehype-katex";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { preprocessBackslashMath } from "./scopyBackslashMathPreprocessor.js";
import { preprocessDollarMathGuards } from "./scopyDollarMathGuards.js";
import { remarkScopyLooseMathRepair } from "./remarkScopyLooseMathRepair.js";
import { remarkScopySourceCitations } from "./remarkScopySourceCitations.js";
import { applySafeHTMLReplacements, preprocessSafeHTML } from "./scopySafeHTMLPreprocessor.js";

export function render(source, policy = {}) {
  return renderInternal(source, policy, 0);
}

function renderInternal(source, policy = {}, depth = 0) {
  const warnings = [];
  const normalizedPolicy = normalizePolicy(policy);

  if (normalizedPolicy.allowRawHTML) {
    warnings.push("raw HTML is not enabled in the first unified renderer bundle");
  }
  const originalSource = String(source || "");
  const tableCodeSpanGuarded = protectTableCodeSpanPipes(originalSource);
  const safeHTML = normalizedPolicy.allowSafeHTMLSubset
    ? preprocessSafeHTML(tableCodeSpanGuarded)
    : { markdown: tableCodeSpanGuarded, replacements: {} };
  const dollarGuarded = preprocessDollarMathGuards(safeHTML.markdown);
  const preprocessed = normalizedPolicy.allowBackslashMath
    ? preprocessBackslashMath(dollarGuarded)
    : { markdown: dollarGuarded, mathCount: 0 };
  const repairMetadata = { repairedMathCount: 0 };
  const processor = unified()
    .use(remarkParse)
    .use(remarkGfm)
    .use(remarkBreaks)
    .use(remarkMath)
    .use(remarkScopyLooseMathRepair, {
      policy: normalizedPolicy,
      metadata: repairMetadata
    })
    .use(remarkScopySourceCitations);
  processor
    .use(remarkRehype, { allowDangerousHtml: false })
    .use(rehypeSanitize, scopySanitizeSchema)
    .use(rehypeScopySourceCitationClass)
    .use(rehypeHighlight, scopyHighlightOptions)
    .use(rehypeKatex, { throwOnError: false, strict: "ignore" })
    .use(rehypeStringify);

  const file = processor.processSync(preprocessed.markdown);
  const html = normalizedPolicy.allowSafeHTMLSubset
    ? applySafeHTMLReplacements(String(file), safeHTML.replacements, (nestedMarkdown) => {
        if (depth > 4) {
          return "";
        }
        return renderInternal(nestedMarkdown, normalizedPolicy, depth + 1).html;
      })
    : String(file);
  return {
    html,
    metadata: {
      renderer: "unified",
      mathCount: countDollarMath(dollarGuarded) + preprocessed.mathCount + repairMetadata.repairedMathCount,
      repairedMathCount: repairMetadata.repairedMathCount,
      warnings
    }
  };
}

const scopySanitizeSchema = {
  ...defaultSchema,
  protocols: {
    ...defaultSchema.protocols,
    href: [...(defaultSchema.protocols?.href || []), "plugin"]
  },
  attributes: {
    ...defaultSchema.attributes,
    a: [
      ...(defaultSchema.attributes?.a || []),
      "className",
      ["dataScopySourceCitation", "true"],
      "dataScopySourceCount"
    ]
  }
};

const scopyHighlightOptions = {
  detect: false,
  plainText: ["text", "txt", "plain", "plaintext"],
  aliases: {
    bash: ["sh", "shell", "zsh"],
    javascript: ["js", "jsx"],
    markdown: ["md"],
    objectivec: ["objc", "objective-c"],
    python: ["py"],
    typescript: ["ts", "tsx"],
    yaml: ["yml"]
  }
};

function rehypeScopySourceCitationClass() {
  return function transformer(tree) {
    visitElements(tree, (node) => {
      if (!node || node.tagName !== "a" || !node.properties) {
        return;
      }
      if (node.properties.dataScopySourceCitation !== "true") {
        return;
      }
      const className = Array.isArray(node.properties.className)
        ? node.properties.className
        : [];
      if (!className.includes("scopy-source-citation-link")) {
        className.push("scopy-source-citation-link");
      }
      node.properties.className = className;
    });
  };
}

function visitElements(node, visitor) {
  if (!node) {
    return;
  }
  if (node.type === "element") {
    visitor(node);
  }
  if (!Array.isArray(node.children)) {
    return;
  }
  for (const child of node.children) {
    visitElements(child, visitor);
  }
}

function normalizePolicy(policy) {
  return {
    profile: String(policy.profile || "plainTextUnknown"),
    allowExplicitMath: policy.allowExplicitMath !== false,
    allowBackslashMath: policy.allowBackslashMath !== false,
    allowLooseMathRepair: policy.allowLooseMathRepair === true,
    allowSafeHTMLSubset: policy.allowSafeHTMLSubset !== false,
    allowRawHTML: policy.allowRawHTML === true,
    policyVersion: String(policy.policyVersion || "")
  };
}

function countDollarMath(source) {
  let count = 0;
  for (let i = 0; i < source.length; i += 1) {
    if (source[i] === "$") {
      if (i > 0 && source[i - 1] === "\\") {
        continue;
      }
      count += 1;
      if (source[i + 1] === "$") {
        i += 1;
      }
    }
  }
  return Math.floor(count / 2);
}

function protectTableCodeSpanPipes(source) {
  if (!source || source.indexOf("|") === -1 || source.indexOf("`") === -1) {
    return source;
  }
  const lines = String(source).split("\n");
  const tableLines = findTableLineIndexes(lines);
  if (tableLines.size === 0) {
    return source;
  }
  const out = lines.slice();
  for (const index of tableLines) {
    if (out[index].indexOf("`") !== -1 && out[index].indexOf("|") !== -1) {
      out[index] = protectCodeSpansInLine(out[index]);
    }
  }
  return out.join("\n");
}

function findTableLineIndexes(lines) {
  const indexes = new Set();
  let activeFence = null;

  for (let i = 0; i < lines.length; i += 1) {
    const fence = fencePrefix(lines[i]);
    if (fence) {
      if (activeFence) {
        if (activeFence.marker === fence.marker && fence.count >= activeFence.count) {
          activeFence = null;
        }
      } else {
        activeFence = fence;
      }
      continue;
    }
    if (activeFence) {
      continue;
    }
    if (!isTableDelimiterLine(lines[i])) {
      continue;
    }

    const headerIndex = i - 1;
    if (headerIndex >= 0 && isTableContentLine(lines[headerIndex])) {
      indexes.add(headerIndex);
    }
    for (let bodyIndex = i + 1; bodyIndex < lines.length && isTableContentLine(lines[bodyIndex]); bodyIndex += 1) {
      indexes.add(bodyIndex);
    }
  }

  return indexes;
}

function fencePrefix(line) {
  const trimmed = String(line || "").trim();
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

function isTableDelimiterLine(line) {
  const raw = String(line || "");
  if (leadingIndentSpaces(raw) > 3 || raw.indexOf("|") === -1) {
    return false;
  }
  let working = raw.trim();
  if (working[0] === "|") {
    working = working.slice(1);
  }
  if (working[working.length - 1] === "|") {
    working = working.slice(0, -1);
  }
  const cells = working.split("|").map((cell) => cell.trim());
  return cells.length > 0 && cells.every(isDelimiterCell);
}

function isDelimiterCell(cell) {
  if (cell.length < 3) {
    return false;
  }
  let body = cell;
  if (body[0] === ":") {
    body = body.slice(1);
  }
  if (body[body.length - 1] === ":") {
    body = body.slice(0, -1);
  }
  return body.length >= 3 && /^-+$/.test(body);
}

function isTableContentLine(line) {
  const raw = String(line || "");
  return leadingIndentSpaces(raw) <= 3 && raw.indexOf("|") !== -1;
}

function leadingIndentSpaces(line) {
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

function protectCodeSpansInLine(line) {
  let result = "";
  let index = 0;
  while (index < line.length) {
    if (line[index] !== "`") {
      result += line[index];
      index += 1;
      continue;
    }

    const openEnd = backtickRunEnd(line, index);
    const runCount = openEnd - index;
    if (runCount > 2) {
      result += line.slice(index, openEnd);
      index = openEnd;
      continue;
    }
    const closeStart = matchingBacktickRunStart(line, openEnd, runCount);
    if (closeStart === -1) {
      result += line[index];
      index += 1;
      continue;
    }

    const closeEnd = closeStart + runCount;
    result += line.slice(index, openEnd);
    result += escapeUnescapedPipes(line.slice(openEnd, closeStart));
    result += line.slice(closeStart, closeEnd);
    index = closeEnd;
  }
  return result;
}

function backtickRunEnd(line, start) {
  let index = start;
  while (index < line.length && line[index] === "`") {
    index += 1;
  }
  return index;
}

function matchingBacktickRunStart(line, start, runCount) {
  let index = start;
  while (index < line.length) {
    if (line[index] !== "`") {
      index += 1;
      continue;
    }
    const runEnd = backtickRunEnd(line, index);
    if (runEnd - index === runCount) {
      return index;
    }
    index = runEnd;
  }
  return -1;
}

function escapeUnescapedPipes(text) {
  let result = "";
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === "|" && !isEscaped(text, i)) {
      result += "\\";
    }
    result += text[i];
  }
  return result;
}

function isEscaped(text, index) {
  let slashCount = 0;
  for (let cursor = index - 1; cursor >= 0 && text[cursor] === "\\"; cursor -= 1) {
    slashCount += 1;
  }
  return slashCount % 2 === 1;
}
