import rehypeHighlight from "rehype-highlight";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { rehypeScopyKatex } from "./rehypeScopyKatex.js";
import { remarkLiteralHTML } from "./remarkLiteralHTML.js";
import {
  remarkScopySafeHTML,
  scopySafeHTMLDetailsHandler,
  scopySafeHTMLInlineHandler
} from "./remarkScopySafeHTML.js";
import { scopyIcon } from "./scopyIcons.js";
import { preprocessBackslashMath } from "./scopyBackslashMathPreprocessor.js";
import { remarkScopyImageGroups } from "./remarkScopyImageGroups.js";
import { remarkScopyPublicCards } from "./remarkScopyPublicCards.js";
import { remarkScopyLinkEnrichment } from "./remarkScopyLinkEnrichment.js";
import { remarkScopyLooseMathRepair } from "./remarkScopyLooseMathRepair.js";
import { isValidExternalHTTPURL } from "./scopyExternalURLPolicy.js";
import {
  isRenderableDataImage,
  remarkScopyRich,
  remarkScopyRichOrdinals,
  scopyImageGroupHandler,
  scopyRichHandler
} from "./remarkScopyRich.js";
import {
  remarkScopySourceCitations,
  scopySourceCitationHandler
} from "./remarkScopySourceCitations.js";

export function render(source, policy = {}) {
  return renderInternal(source, policy, 0);
}

function renderInternal(source, policy = {}) {
  const warnings = [];
  const normalizedPolicy = normalizePolicy(policy);
  const originalSource = String(source || "");
  const tableCodeSpanGuarded = protectTableCodeSpanPipes(originalSource);
  const preprocessed = preprocessBackslashMath(tableCodeSpanGuarded);
  const repairMetadata = { repairedMathCount: 0 };
  const processor = unified()
    .use(remarkParse)
    .use(remarkGfm, { singleTilde: false })
    .use(remarkBreaks)
    .use(remarkMath, { singleDollarTextMath: false })
    .use(remarkScopyLooseMathRepair, {
      policy: normalizedPolicy,
      metadata: repairMetadata
    })
    .use(remarkScopySourceCitations)
    .use(remarkScopyRich)
    .use(remarkScopyImageGroups)
    .use(remarkScopyPublicCards)
    .use(remarkScopyLinkEnrichment, normalizedPolicy.linkEnrichment)
    .use(remarkScopyRichOrdinals)
    .use(remarkScopySafeHTML)
    .use(remarkLiteralHTML);
  processor
    .use(remarkRehype, {
      allowDangerousHtml: false,
      clobberPrefix: "scopy-",
      handlers: {
        scopyImageGroup: scopyImageGroupHandler,
        scopyRich: scopyRichHandler,
        scopySafeHTMLDetails: scopySafeHTMLDetailsHandler,
        scopySafeHTMLInline: scopySafeHTMLInlineHandler,
        scopySourceCitation: scopySourceCitationHandler
      }
    })
    .use(rehypeGuardDataImages)
    .use(rehypeSanitize, scopySanitizeSchema)
    .use(rehypeScopyLinkSemantics)
    .use(rehypeScopyKatex, { failureMode: "relaxed" })
    .use(rehypeHighlight, scopyHighlightOptions)
    .use(rehypeStringify);

  const file = processor.processSync(preprocessed.markdown);
  const html = String(file);
  for (const message of file.messages) {
    warnings.push(String(message.reason || message));
  }
  return {
    html,
    metadata: {
      mathCount: Number(file.data.scopyMathCount || 0),
      mathStrictCount: Number(file.data.scopyMathStrictCount || 0),
      mathRelaxedCount: Number(file.data.scopyMathRelaxedCount || 0),
      mathErrorCount: Number(file.data.scopyMathErrorCount || 0),
      repairedMathCount: repairMetadata.repairedMathCount,
      warnings
    }
  };
}

const scopySanitizeRequired = { ...(defaultSchema.required || {}) };
delete scopySanitizeRequired.input;

const scopySanitizeSchema = {
  ...defaultSchema,
  required: scopySanitizeRequired,
  // remark-rehype already namespaces every renderer-generated footnote ID.
  // A second sanitizer prefix would break href/id pairs.
  clobberPrefix: "",
  protocols: {
    ...defaultSchema.protocols,
    href: ["http", "https", "plugin"],
    src: [...(defaultSchema.protocols?.src || []), "data"]
  },
  tagNames: [...new Set([
    ...(defaultSchema.tagNames || []),
    "article", "button", "circle", "dd", "defs", "details", "div", "dl", "dt", "figcaption", "figure", "footer",
    "g", "header", "input", "label", "linearGradient", "output", "path", "polygon", "polyline",
    "section", "span", "stop", "sub", "summary", "sup", "svg", "text", "time", "title", "u", "kbd", "mark"
  ])],
  attributes: {
    ...defaultSchema.attributes,
    a: [
      ...withoutClassName(defaultSchema.attributes?.a),
      ["className", /^scopy-/],
      ["dataScopySourceCitation", "true"],
      "ariaLabel",
      "ariaDescribedBy"
    ],
    article: ["className", "id"],
    button: [
      "id",
      ["className", /^scopy-/],
      ["type", "button"],
      ["dataScopyAction", "currency-input", "weather-unit", "weather-day", "finance-range", "lightbox-open", "lightbox-close", "lightbox-prev", "lightbox-next", "chart-probe"],
      ["dataScopyCurrencySide", "from", "to"],
      ["dataScopyUnit", "F", "C"],
      ["dataScopyIndex", /^\d+$/],
      "dataScopyLightboxTitle",
      "dataScopyLightboxSource",
      "ariaLabel",
      "ariaPressed",
      "ariaSelected",
      "ariaChecked",
      "ariaControls",
      "ariaDisabled",
      "tabIndex",
      "disabled"
    ],
    circle: [
      "id", "className", "cx", "cy", "r", "fill", "stroke", "strokeWidth", "tabIndex",
      ["dataScopyChartPoint", "true"],
      ["dataScopyIndex", /^\d+$/],
      ["dataScopyPointIndex", /^\d+$/],
      ["dataScopyX", /^-?\d+(?:\.\d+)?$/],
      "dataScopyLabel",
      "dataScopyDisplay"
    ],
    dd: ["className"],
    details: [["className", "scopy-safe-details"], "open"],
    div: [
      ["className", /^scopy-/],
      "id",
      "role",
      "hidden",
      "ariaLabel",
      "ariaLabelledBy",
      "ariaHidden",
      "ariaModal",
      "ariaLive",
      ["dataScopyWeatherPanel", /^\d+$/],
      ["dataScopyFinancePanel", /^\d+$/],
      ["dataScopyIndex", /^\d+$/],
      ["dataScopyLightbox", "true"],
      ["dataScopyLightboxMetaPanel", /^\d+$/],
      ["dataScopyChartTooltip", "true"]
    ],
    dl: ["className", "ariaLabel"],
    dt: ["className"],
    figcaption: ["className"],
    figure: [
      ["className", /^scopy-/],
      "id",
      "hidden",
      "role",
      "ariaLabel",
      "ariaHidden",
      "tabIndex",
      ["dataScopyAction", "chart-probe"],
      ["dataScopyChartCount", /^\d+$/],
      ["dataScopyUnitValue", "F", "C"]
    ],
    footer: ["className"],
    g: ["className"],
    h3: [...(defaultSchema.attributes?.h3 || []), "className"],
    h4: [...(defaultSchema.attributes?.h4 || []), "className"],
    img: [
      ...(defaultSchema.attributes?.img || []),
      ["className", /^scopy-/],
      ["dataScopyDeferredImage", "true"],
      ["dataScopyLightboxImage", "true"]
    ],
    input: [
      ...withoutAttributes(defaultSchema.attributes?.input, ["disabled", "type"]),
      ["className", /^scopy-/],
      ["type", "text", "checkbox"],
      "checked",
      "disabled",
      ["inputMode", "decimal"],
      "maxLength",
      ["autoComplete", "off"],
      ["spellCheck", "false"],
      ["dataScopyAction", "currency-input"],
      ["dataScopyCurrencySide", "from", "to"],
      "value",
      "ariaLabel",
      "ariaInvalid"
    ],
    label: [...(defaultSchema.attributes?.label || []), ["className", /^scopy-/], "htmlFor"],
    linearGradient: ["id", "x1", "x2", "y1", "y2", "gradientUnits"],
    li: [...withoutClassName(defaultSchema.attributes?.li), ["className", "task-list-item", /^scopy-/]],
    ol: [...withoutClassName(defaultSchema.attributes?.ol), ["className", "contains-task-list", /^scopy-/], "ariaLabel"],
    p: [
      ...(defaultSchema.attributes?.p || []),
      ["className", /^scopy-/],
      ["dataScopyLightboxCounter", "true"],
      ["dataScopyLightboxSource", "true"],
      ["dataScopyLightboxTitle", "true"],
      "ariaLive"
    ],
    path: ["className", "d", "fill", "stroke", "strokeWidth", "strokeLinecap", "strokeLinejoin", "opacity"],
    polygon: ["points", "fill", "opacity"],
    polyline: ["points", "fill", "stroke", "strokeWidth"],
    section: [
      ["className", /^scopy-/],
      ["dataType", "news", "web_results", "image_group", "weather", "finance", "currency", "video", "product", "product_carousel", "entity", "map"],
      ["dataState", "ready", "partial", "empty", "error"],
      ["dataScopyVersion", "2"],
      ["dataScopyInteractive", "true", "false"],
      ["dataScopyUnit", "F", "C"],
      ["dataScopyDayIndex", /^\d+$/],
      ["dataScopyRangeIndex", /^\d+$/],
      ["dataScopyLightboxIndex", /^\d+$/],
      ["dataScopyRate", /^\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i],
      ["dataScopyFractionDigits", /^\d+$/],
      "role",
      "ariaLabel",
      ["dir", "auto"]
    ],
    span: [
      ["className", /^scopy-/],
      "role",
      "ariaLabel",
      "ariaHidden",
      "hidden",
      ["dataScopyUnitValue", "F", "C"],
      ["dataScopyUnitLabel", "F", "C"],
      ["dataScopyImageTitle", "true"],
      ["dataScopyTooltipLabel", "true"],
      ["dataScopyTooltipDisplay", "true"],
      ["dataScopyRatingHalves", /^(?:10|[0-9])$/]
    ],
    stop: ["offset", "stopColor", "stopOpacity"],
    sub: [["className", "scopy-safe-html-sub"]],
    summary: [["className", "scopy-safe-summary"]],
    strong: [...(defaultSchema.attributes?.strong || []), ["dataScopyTooltipDisplay", "true"]],
    sup: [
      ...(defaultSchema.attributes?.sup || []),
      ["className", "scopy-safe-html-sup"]
    ],
    svg: ["className", "viewBox", "width", "height", "role", "ariaLabel", "ariaHidden", "focusable"],
    text: ["className", "x", "y", "dx", "dy", "textAnchor", "dominantBaseline"],
    time: ["className", "dateTime"],
    u: [["className", "scopy-safe-html-u"]],
    kbd: [["className", "scopy-safe-html-kbd"]],
    mark: [["className", "scopy-safe-html-mark"]],
    ul: [...withoutClassName(defaultSchema.attributes?.ul), ["className", "contains-task-list", /^scopy-/], "ariaLabel"]
  }
};

function withoutClassName(attributes = []) {
  return attributes.filter((attribute) => attribute !== "className" && !(Array.isArray(attribute) && attribute[0] === "className"));
}

function withoutAttributes(attributes = [], names = []) {
  const blocked = new Set(names);
  return attributes.filter((attribute) => {
    const name = Array.isArray(attribute) ? attribute[0] : attribute;
    return !blocked.has(name);
  });
}

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

function rehypeScopyLinkSemantics() {
  return function transformer(tree) {
    visitElements(tree, (node) => {
      if (!node || node.tagName !== "a" || !node.properties) {
        return;
      }
      const className = Array.isArray(node.properties.className)
        ? node.properties.className
        : [];
      if (node.properties.dataFootnoteRef != null ||
          node.properties.dataFootnoteBackref != null ||
          className.some((name) => String(name).startsWith("data-footnote-") || String(name).startsWith("footnote-"))) {
        return;
      }
      if (className.some((name) => String(name).startsWith("scopy-rich-") || String(name).startsWith("scopy-source-citation-"))) {
        return;
      }
      const href = String(node.properties.href || "");
      if (isSameDocumentFragment(href)) {
        className.push("scopy-link", "scopy-link--internal");
        node.properties.className = className;
        return;
      }
      if (isValidExternalHTTPURL(href)) {
        className.push("scopy-link", "scopy-link--external");
        node.properties.className = className;
        node.children = [
          elementNode("span", { className: ["scopy-link__label"] }, node.children || []),
          scopyIcon("external-link")
        ];
        return;
      }
      if (isLocalPathTarget(href)) {
        const kind = localFileKind(href);
        const resolvable = href.startsWith("/") || href.startsWith("~/");
        className.push("scopy-link", "scopy-link--file");
        className.push(resolvable ? "scopy-link--file-resolvable" : "scopy-link--file-inert");
        node.properties.className = className;
        node.properties.dataScopyFileKind = kind;
        if (resolvable) {
          node.properties.href = scopyFileURL(href);
        } else {
          delete node.properties.href;
          node.properties.ariaDisabled = "true";
        }
        const icon = scopyIcon(iconNameForFileKind(kind));
        icon.properties.className.push("scopy-file-icon");
        node.children = [
          icon,
          elementNode("span", { className: ["scopy-link__label"] }, node.children || [])
        ];
        return;
      }
      className.push("scopy-link", href.startsWith("plugin:") ? "scopy-link--plugin" : "scopy-link--inert");
      node.properties.className = className;
    });
  };
}

function isSameDocumentFragment(value) {
  return /^#[^\u0000-\u0020\u007f]+$/u.test(value);
}

function isLocalPathTarget(value) {
  if (!value || /[\u0000-\u001f\u007f]/u.test(value) || value.startsWith("#") || value.startsWith("//")) {
    return false;
  }
  if (/^[a-z][a-z0-9+.-]*:/i.test(value)) return false;
  return value.startsWith("/") ||
    value.startsWith("~/") ||
    value.startsWith("./") ||
    value.startsWith("../") ||
    /^[^?#]+(?:\/[^?#]+)+(?::\d+(?::\d+)?)?(?:[?#].*)?$/u.test(value);
}

function localFileKind(value) {
  const clean = String(value).split(/[?#]/, 1)[0].replace(/:\d+(?::\d+)?$/, "").toLowerCase();
  if (/\.(?:md|markdown|txt|rtf)$/.test(clean)) return "document";
  if (/\.(?:js|jsx|mjs|cjs)$/.test(clean)) return "javascript";
  if (/\.(?:png|jpe?g|gif|webp|svg|heic|tiff?)$/.test(clean)) return "image";
  if (/\.(?:swift|html?|css|json|py|ts|tsx|java|kt|kts|c|cc|cpp|h|hpp|rs|go|rb|php|sh|zsh|bash|sql|ya?ml|toml|xml)$/.test(clean)) {
    return "code";
  }
  return "document";
}

function iconNameForFileKind(kind) {
  if (kind === "javascript") return "javascript";
  if (kind === "image") return "image";
  if (kind === "code") return "code";
  return "document";
}

function scopyFileURL(path) {
  const normalized = path.startsWith("~/") ? "/~/" + path.slice(2) : path;
  const encoded = encodeURI(normalized)
    .replace(/%25(?=[0-9a-f]{2})/gi, "%")
    .replace(/#/g, "%23")
    .replace(/\?/g, "%3F");
  return "scopy-file:" + encoded;
}

function elementNode(tagName, properties, children) {
  return { type: "element", tagName, properties, children };
}

function rehypeGuardDataImages() {
  return function transformer(tree) {
    visitElements(tree, (node) => {
      if (node.tagName !== "img" || !node.properties) return;
      const src = String(node.properties.src || "");
      if (src.startsWith("data:") && (node.properties.dataScopyTrustedImage !== "true" || !isRenderableDataImage(src))) {
        delete node.properties.src;
      }
      delete node.properties.dataScopyTrustedImage;
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
    allowLooseMathRepair: policy.allowLooseMathRepair === true,
    policyVersion: String(policy.policyVersion || ""),
    linkEnrichment: policy.linkEnrichment && typeof policy.linkEnrichment === "object" && !Array.isArray(policy.linkEnrichment)
      ? policy.linkEnrichment
      : null
  };
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
