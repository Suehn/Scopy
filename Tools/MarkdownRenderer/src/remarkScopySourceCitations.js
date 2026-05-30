export function remarkScopySourceCitations() {
  return function transformer(tree) {
    const definitions = collectDefinitions(tree);
    visitParents(tree, (node, parent) => {
      if (!parent || !Array.isArray(parent.children)) {
        return;
      }
      decorateCitationLinks(parent.children, definitions);
    });
  };
}

function collectDefinitions(tree) {
  const definitions = new Map();
  visitParents(tree, (node) => {
    if (!node || node.type !== "definition") {
      return;
    }
    const key = normalizeIdentifier(node.identifier || node.label);
    if (!key || definitions.has(key)) {
      return;
    }
    definitions.set(key, {
      url: String(node.url || ""),
      title: node.title == null ? "" : String(node.title)
    });
  });
  return definitions;
}

function decorateCitationLinks(children, definitions) {
  for (let i = 0; i < children.length; i += 1) {
    const group = citationGroupAt(children, i, definitions);
    if (!group) {
      continue;
    }
    stripCitationGroup(children, group);
    decorateLinkNode(group.primary.node, group.count);
    rewriteLinkLabel(group.primary.node, group.primary.label);
    i = group.endIndex;
  }
}

function citationForNode(node, definitions) {
  if (!node || (node.type !== "link" && node.type !== "linkReference")) {
    return null;
  }
  const labelParts = splitCitationCount(plainText(node).trim());
  if (!isSourceLabel(labelParts.label)) {
    return null;
  }
  if (node.type === "link") {
    const url = String(node.url || "");
    return isHTTPURL(url) ? { label: labelParts.label, count: labelParts.count, url } : null;
  }
  const definition = definitions.get(normalizeIdentifier(node.identifier || node.label));
  if (!definition || !isHTTPURL(definition.url)) {
    return null;
  }
  return { label: labelParts.label, count: labelParts.count, url: definition.url };
}

function citationGroupAt(children, index, definitions) {
  const before = previousText(children, index);
  if (!before || !/\s*\($/.test(before.value || "")) {
    return null;
  }

  const primary = citationForNode(children[index], definitions);
  if (!primary) {
    return null;
  }

  const citations = [{ ...primary, node: children[index], index }];
  let cursor = index + 1;
  while (cursor < children.length) {
    const node = children[cursor];
    if (!node) {
      return null;
    }
    if (node.type === "text") {
      const value = String(node.value || "");
      if (/^[\s,;，、]*\)/.test(value)) {
        const explicitCount = Math.max(0, primary.count || 0);
        return {
          primary: citations[0],
          count: Math.max(explicitCount, citations.length - 1),
          beforeIndex: children.indexOf(before),
          endIndex: cursor
        };
      }
      if (/^[\s,;，、]+$/.test(value)) {
        cursor += 1;
        continue;
      }
      return null;
    }
    const citation = citationForNode(node, definitions);
    if (!citation) {
      return null;
    }
    citations.push({ ...citation, node, index: cursor });
    cursor += 1;
  }
  return null;
}

function stripCitationGroup(children, group) {
  const before = children[group.beforeIndex];
  const after = children[group.endIndex];
  if (before && before.type === "text") {
    before.value = String(before.value || "").replace(/\s*\($/, "");
  }
  if (after && after.type === "text") {
    after.value = String(after.value || "").replace(/^[\s,;，、]*\)/, "");
  }
  if (group.endIndex > group.primary.index + 1) {
    children.splice(group.primary.index + 1, group.endIndex - group.primary.index - 1);
    group.endIndex = group.primary.index + 1;
  }
}

function decorateLinkNode(node, count) {
  node.data = node.data || {};
  node.data.hProperties = node.data.hProperties || {};
  const props = node.data.hProperties;
  const classNames = Array.isArray(props.className)
    ? props.className.slice()
    : typeof props.className === "string"
      ? props.className.split(/\s+/).filter(Boolean)
      : [];
  if (!classNames.includes("scopy-source-citation-link")) {
    classNames.push("scopy-source-citation-link");
  }
  props.className = classNames;
  props.dataScopySourceCitation = "true";
  if (count > 0) {
    props.dataScopySourceCount = `+${count}`;
  }
}

function rewriteLinkLabel(node, label) {
  if (!node || !Array.isArray(node.children)) {
    return;
  }
  node.children = [{ type: "text", value: label }];
}

function splitCitationCount(label) {
  const text = String(label || "").trim();
  const match = /^(.*\S)\s+\+([1-9]\d{0,2})$/.exec(text);
  if (!match) {
    return { label: text, count: 0 };
  }
  return { label: match[1].trim(), count: Number(match[2]) || 0 };
}

function previousText(children, index) {
  for (let i = index - 1; i >= 0; i -= 1) {
    const node = children[i];
    if (!node) {
      continue;
    }
    if (node.type === "text") {
      return node;
    }
    if (!isIgnorableTextNode(node)) {
      return null;
    }
  }
  return null;
}

function nextText(children, index) {
  for (let i = index + 1; i < children.length; i += 1) {
    const node = children[i];
    if (!node) {
      continue;
    }
    if (node.type === "text") {
      return node;
    }
    if (!isIgnorableTextNode(node)) {
      return null;
    }
  }
  return null;
}

function isIgnorableTextNode(node) {
  return node && node.type === "text" && !String(node.value || "").trim();
}

function plainText(node) {
  if (!node) {
    return "";
  }
  if (node.type === "text" || node.type === "inlineCode") {
    return String(node.value || "");
  }
  if (!Array.isArray(node.children)) {
    return "";
  }
  return node.children.map(plainText).join("");
}

function isSourceLabel(label) {
  const text = String(label || "").trim();
  if (!text || text.length > 48 || /[\r\n[\]()]/.test(text)) {
    return false;
  }
  return /[A-Z]/.test(text) || /[\u3400-\u9fff\uf900-\ufaff]/u.test(text) || text.includes(".");
}

function isHTTPURL(url) {
  return /^https?:\/\//i.test(String(url || "").trim());
}

function normalizeIdentifier(value) {
  return String(value || "").trim().replace(/\s+/g, " ").toUpperCase();
}

function visitParents(node, visitor, parent = null) {
  visitor(node, parent);
  if (!node || !Array.isArray(node.children)) {
    return;
  }
  for (const child of node.children) {
    visitParents(child, visitor, node);
  }
}
