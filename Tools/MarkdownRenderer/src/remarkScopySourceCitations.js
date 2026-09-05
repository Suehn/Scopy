import { isValidExternalHTTPURL } from "./scopyExternalURLPolicy.js";
import { scopySourceIcon } from "./scopySourceIcon.js";

export function remarkScopySourceCitations() {
  return function transformer(tree) {
    const definitions = collectDefinitions(tree);
    visit(tree, (node) => {
      if (node && Array.isArray(node.children)) promoteCitationGroups(node.children, definitions);
    });
  };
}

export function scopySourceCitationHandler(_state, node) {
  const citations = Array.isArray(node.citations) ? node.citations : [];
  const primary = citations[0];
  if (!primary) return text("");
  const count = Math.max(0, Number(node.count) || 0);
  const primaryChildren = [
    citationOriginIcon(primary.url),
    element("span", { className: ["scopy-source-citation-label"] }, [text(primary.label)])
  ];
  if (count > 0) {
    primaryChildren.push(element("span", {
      className: ["scopy-source-citation-count"],
      ariaLabel: `${count} additional ${count === 1 ? "source" : "sources"}`
    }, [text(`+${count}`)]));
  }
  const primaryLink = element("a", {
    href: primary.url,
    title: primary.title || undefined,
    className: ["scopy-source-citation-link"],
    dataScopySourceCitation: "true",
    ariaLabel: count > 0 ? `${primary.label}, ${count} additional ${count === 1 ? "source" : "sources"}` : primary.label
  }, primaryChildren);
  const supporting = citations.slice(1);
  const supportingList = supporting.length > 0
    ? element("span", {
        className: ["scopy-source-citation-supporting"],
        role: "list",
        ariaLabel: "Supporting sources"
      }, supporting.map((citation) => element("span", {
        className: ["scopy-source-citation-supporting-item"],
        role: "listitem"
      }, [
        element("a", {
          href: citation.url,
          title: citation.title || undefined,
          className: ["scopy-source-citation-supporting-link"],
          ariaLabel: `Supporting source: ${citation.label}`
        }, [citationOriginIcon(citation.url), text(citation.label)])
      ])))
    : null;
  return element("span", { className: ["scopy-source-citation-group"] }, [primaryLink, supportingList].filter(Boolean));
}

function collectDefinitions(tree) {
  const definitions = new Map();
  visit(tree, (node) => {
    if (!node || node.type !== "definition") return;
    const key = normalizeIdentifier(node.identifier || node.label);
    if (!key || definitions.has(key)) return;
    definitions.set(key, {
      url: String(node.url || ""),
      title: node.title == null ? "" : String(node.title)
    });
  });
  return definitions;
}

function promoteCitationGroups(children, definitions) {
  for (let index = 0; index < children.length; index += 1) {
    const group = citationGroupAt(children, index, definitions);
    if (!group) continue;
    const before = children[group.beforeIndex];
    const after = children[group.endIndex];
    before.value = String(before.value || "").replace(/\s*\($/, "");
    after.value = String(after.value || "").replace(/^[\s,;，、]*\)/, "");
    children.splice(group.primaryIndex, group.endIndex - group.primaryIndex, {
      type: "scopySourceCitation",
      citations: group.citations,
      count: group.count
    });
    index = group.primaryIndex;
  }
}

function citationGroupAt(children, index, definitions) {
  const before = previousText(children, index);
  if (!before || !/\s*\($/.test(before.node.value || "")) return null;
  const primary = citationForNode(children[index], definitions);
  if (!primary) return null;
  const citations = [primary];
  let cursor = index + 1;
  while (cursor < children.length) {
    const node = children[cursor];
    if (!node) return null;
    if (node.type === "text") {
      const value = String(node.value || "");
      if (/^[\s,;，、]*\)/.test(value)) {
        return {
          citations,
          count: Math.max(primary.explicitCount, citations.length - 1),
          beforeIndex: before.index,
          primaryIndex: index,
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
    if (!citation) return null;
    citations.push(citation);
    cursor += 1;
  }
  return null;
}

function citationForNode(node, definitions) {
  if (!node || (node.type !== "link" && node.type !== "linkReference")) return null;
  const parts = splitCitationCount(plainText(node).trim());
  if (!isSourceLabel(parts.label)) return null;
  if (node.type === "link") {
    const url = String(node.url || "");
    return isValidExternalHTTPURL(url) ? {
      label: parts.label,
      explicitCount: parts.count,
      url,
      title: node.title == null ? "" : String(node.title)
    } : null;
  }
  const definition = definitions.get(normalizeIdentifier(node.identifier || node.label));
  return definition && isValidExternalHTTPURL(definition.url) ? {
    label: parts.label,
    explicitCount: parts.count,
    url: definition.url,
    title: definition.title
  } : null;
}

function splitCitationCount(label) {
  const value = String(label || "").trim();
  const match = /^(.*\S)\s+\+([1-9]\d{0,2})$/.exec(value);
  return match ? { label: match[1].trim(), count: Number(match[2]) || 0 } : { label: value, count: 0 };
}

function previousText(children, index) {
  for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
    const node = children[cursor];
    if (!node) continue;
    if (node.type === "text") return { node, index: cursor };
    return null;
  }
  return null;
}

function plainText(node) {
  if (!node) return "";
  if (node.type === "text" || node.type === "inlineCode") return String(node.value || "");
  return Array.isArray(node.children) ? node.children.map(plainText).join("") : "";
}

function isSourceLabel(label) {
  const value = String(label || "").trim();
  if (!value || value.length > 48 || /[\r\n[\]()]/.test(value)) return false;
  return /[A-Z]/.test(value) || /[\u3400-\u9fff\uf900-\ufaff]/u.test(value) || value.includes(".");
}

function normalizeIdentifier(value) {
  return String(value || "").trim().replace(/\s+/g, " ").toUpperCase();
}

function citationOriginIcon(url) {
  const icon = scopySourceIcon(url, ["scopy-source-citation-origin-icon"], "scopy-source-citation-favicon");
  if (icon.tagName === "svg") {
    icon.properties.width = 12;
    icon.properties.height = 12;
  }
  return icon;
}

function element(tagName, properties = {}, children = []) {
  const clean = {};
  for (const [key, value] of Object.entries(properties)) {
    if (value !== undefined) clean[key] = value;
  }
  return { type: "element", tagName, properties: clean, children };
}

function text(value) {
  return { type: "text", value: String(value) };
}

function visit(node, visitor) {
  visitor(node);
  if (!node || !Array.isArray(node.children)) return;
  for (const child of node.children) visit(child, visitor);
}
