const SAFE_INLINE_TAGS = new Set(["u", "kbd", "mark", "sub", "sup"]);
const PHRASING_PARENT_TYPES = new Set([
  "delete",
  "emphasis",
  "heading",
  "link",
  "linkReference",
  "paragraph",
  "scopySafeHTMLInline",
  "strong",
  "tableCell"
]);
const FLOW_PARENT_TYPES = new Set([
  "blockquote",
  "footnoteDefinition",
  "listItem",
  "root",
  "scopySafeHTMLDetails"
]);
const ASCII_WHITESPACE = "[ \\t\\r\\n\\f]";
const MAX_SAFE_NESTING_DEPTH = 64;
const MAX_SUMMARY_LENGTH = 4_096;

export function remarkScopySafeHTML() {
  return function transformer(tree) {
    transformNode(tree);
  };
}

export function scopySafeHTMLInlineHandler(state, node) {
  const tagName = SAFE_INLINE_TAGS.has(node.tagName) ? node.tagName : "span";
  return element(tagName, { className: [`scopy-safe-html-${tagName}`] }, state.all(node));
}

export function scopySafeHTMLDetailsHandler(state, node) {
  const properties = { className: ["scopy-safe-details"] };
  if (node.open === true) properties.open = true;
  return element("details", properties, [
    element("summary", { className: ["scopy-safe-summary"] }, [text(node.summary)]),
    ...state.all(node)
  ]);
}

function transformNode(node) {
  if (!node || !Array.isArray(node.children)) return;

  node.children = node.children.filter((child) => !isCompleteHTMLComment(child));
  if (FLOW_PARENT_TYPES.has(node.type)) {
    node.children = foldSafeDetails(node.children);
  }

  for (const child of node.children) transformNode(child);

  if (PHRASING_PARENT_TYPES.has(node.type)) {
    node.children = foldInlineSafeHTML(node.children);
  }
}

function foldInlineSafeHTML(children) {
  const root = { children: [] };
  const stack = [root];

  for (const child of children) {
    const opened = parseInlineOpening(child);
    if (opened) {
      if (stack.length > MAX_SAFE_NESTING_DEPTH) return children;
      stack.push({ tagName: opened, opener: child, children: [] });
      continue;
    }

    const closed = parseInlineClosing(child);
    if (closed) {
      const frame = stack[stack.length - 1];
      if (stack.length === 1 || frame.tagName !== closed) return children;
      stack.pop();
      stack[stack.length - 1].children.push({
        type: "scopySafeHTMLInline",
        tagName: frame.tagName,
        children: frame.children,
        position: joinedPosition(frame.opener, child)
      });
      continue;
    }

    stack[stack.length - 1].children.push(child);
  }

  return stack.length === 1 ? root.children : children;
}

function foldSafeDetails(children) {
  const root = { kind: "root", children: [] };
  const stack = [root];
  let validDepth = 0;

  for (const child of children) {
    const opening = parseDetailsOpening(child);
    if (opening) {
      const kind = validDepth < MAX_SAFE_NESTING_DEPTH ? "valid" : "invalid";
      stack.push({
        kind,
        opener: child,
        opening,
        children: []
      });
      if (kind === "valid") validDepth += 1;
      continue;
    }

    if (isPotentialDetailsOpening(child)) {
      stack.push({ kind: "invalid", opener: child, children: [] });
      continue;
    }

    if (isDetailsClosing(child)) {
      if (stack.length === 1) {
        root.children.push(child);
        continue;
      }

      const frame = stack.pop();
      const parent = stack[stack.length - 1];
      if (frame.kind === "valid") {
        validDepth -= 1;
        parent.children.push({
          type: "scopySafeHTMLDetails",
          summary: frame.opening.summary,
          open: frame.opening.open,
          children: frame.children,
          position: joinedPosition(frame.opener, child)
        });
      } else {
        parent.children.push(frame.opener, ...frame.children, child);
      }
      continue;
    }

    stack[stack.length - 1].children.push(child);
  }

  while (stack.length > 1) {
    const frame = stack.pop();
    if (frame.kind === "valid") validDepth -= 1;
    stack[stack.length - 1].children.push(frame.opener, ...frame.children);
  }
  return root.children;
}

function parseInlineOpening(node) {
  if (!isHTML(node)) return null;
  const match = new RegExp(`^${ASCII_WHITESPACE}*<(u|kbd|mark|sub|sup)${ASCII_WHITESPACE}*>${ASCII_WHITESPACE}*$`, "i")
    .exec(String(node.value || ""));
  return match ? match[1].toLowerCase() : null;
}

function parseInlineClosing(node) {
  if (!isHTML(node)) return null;
  const match = new RegExp(`^${ASCII_WHITESPACE}*</(u|kbd|mark|sub|sup)${ASCII_WHITESPACE}*>${ASCII_WHITESPACE}*$`, "i")
    .exec(String(node.value || ""));
  return match ? match[1].toLowerCase() : null;
}

function parseDetailsOpening(node) {
  if (!isHTML(node)) return null;
  const pattern = new RegExp(
    `^${ASCII_WHITESPACE}*<details(${ASCII_WHITESPACE}+open)?${ASCII_WHITESPACE}*>` +
    `${ASCII_WHITESPACE}*<summary${ASCII_WHITESPACE}*>([^<>]*)</summary${ASCII_WHITESPACE}*>${ASCII_WHITESPACE}*$`,
    "i"
  );
  const match = pattern.exec(String(node.value || ""));
  if (!match) return null;
  const summary = match[2];
  if (!summary.trim() || summary.length > MAX_SUMMARY_LENGTH) return null;
  return { summary, open: Boolean(match[1]) };
}

function isPotentialDetailsOpening(node) {
  if (!isHTML(node)) return false;
  const value = String(node.value || "");
  const startsWithDetails = new RegExp(`^${ASCII_WHITESPACE}*<details(?=${ASCII_WHITESPACE}|/|>)`, "i").test(value);
  if (!startsWithDetails) return false;
  return !new RegExp(`</details${ASCII_WHITESPACE}*>`, "i").test(value);
}

function isDetailsClosing(node) {
  return isHTML(node) && new RegExp(
    `^${ASCII_WHITESPACE}*</details${ASCII_WHITESPACE}*>${ASCII_WHITESPACE}*$`,
    "i"
  ).test(String(node.value || ""));
}

function isCompleteHTMLComment(node) {
  if (!isHTML(node)) return false;
  const value = String(node.value || "").replace(
    new RegExp(`^${ASCII_WHITESPACE}+|${ASCII_WHITESPACE}+$`, "g"),
    ""
  );
  if (value.length < 7 || !value.startsWith("<!--") || !value.endsWith("-->")) return false;
  const body = value.slice(4, -3);
  return !body.startsWith(">") &&
    !body.startsWith("->") &&
    !body.endsWith("<!-") &&
    !body.includes("<!--") &&
    !body.includes("-->") &&
    !body.includes("--!>");
}

function isHTML(node) {
  return node?.type === "html";
}

function joinedPosition(first, last) {
  if (!first?.position || !last?.position) return undefined;
  return { start: first.position.start, end: last.position.end };
}

function element(tagName, properties = {}, children = []) {
  return { type: "element", tagName, properties, children };
}

function text(value) {
  return { type: "text", value: String(value || "") };
}
