import { hostLabel, normalizeRichSurface } from "./remarkScopyRich.js";

// Frozen link-enrichment presentation. The backend LinkEnrichmentService may fetch Open
// Graph metadata and downscaled data-URI imagery for links in an assistant copy, freeze
// them, and pass the result into the render policy. This plugin never fetches anything:
// it only maps that frozen per-URL data onto two exact degraded shapes —
//
//   1. a run of two or more bare-link-only paragraphs or a bare-link list  -> news cards
//   2. a lone link-only paragraph                                          -> one wide news card
//
// A run is promoted only when every link has an enrichment entry AND the visible labels
// are degradation artifacts rather than authored descriptions: either all labels in the
// run are identical (ChatGPT's news degradation repeats the bare source name) or each
// label matches its link's source/host. A lone link is promoted only when its label is
// URL-ish, source-ish, or a prefix relationship with the fetched title — descriptive
// authored labels stay ordinary links, matching the official presentation. Every
// candidate passes the strict v2 `normalizeRichSurface` authority.

const MAX_ENRICHED_ITEMS = 12;

export function remarkScopyLinkEnrichment(enrichment) {
  const entries = normalizeEnrichmentMap(enrichment);
  return function transformer(tree) {
    if (!entries) return;
    visitParents(tree, (parent) => {
      if (!parent || !Array.isArray(parent.children)) return;
      const children = parent.children;
      for (let index = 0; index < children.length;) {
        const advance =
          adaptLinkList(children, index, entries) ??
          adaptLinkRun(children, index, entries) ??
          adaptLoneLink(children, index, entries) ??
          1;
        index += advance;
      }
    });
  };
}

function normalizeEnrichmentMap(enrichment) {
  if (!enrichment || typeof enrichment !== "object" || Array.isArray(enrichment)) return null;
  const entries = new Map();
  for (const [url, value] of Object.entries(enrichment).slice(0, 48)) {
    if (!value || typeof value !== "object" || typeof value.title !== "string" || !value.title.trim()) {
      continue;
    }
    entries.set(url, value);
  }
  return entries.size > 0 ? entries : null;
}

function adaptLinkList(children, index, entries) {
  const node = children[index];
  if (node?.type !== "list" || !Array.isArray(node.children) || node.children.length < 2) return null;
  const links = [];
  for (const item of node.children) {
    if (item?.type !== "listItem" || !Array.isArray(item.children) || item.children.length !== 1) return null;
    const link = soleLink(item.children[0]);
    if (!link) return null;
    links.push(link);
  }
  const surface = newsSurface(links, entries);
  if (!surface) return null;
  children.splice(index, 1, richNode(surface, node));
  return 1;
}

function adaptLinkRun(children, index, entries) {
  const links = [];
  let end = index;
  while (end < children.length) {
    const link = soleLink(children[end]);
    if (!link) break;
    links.push(link);
    end += 1;
  }
  if (links.length < 2) return null;
  const surface = newsSurface(links, entries);
  if (!surface) return null;
  children.splice(index, end - index, richNode(surface, children[index]));
  return 1;
}

function adaptLoneLink(children, index, entries) {
  const link = soleLink(children[index]);
  if (!link) return null;
  const entry = entries.get(String(link.url || ""));
  if (!entry) return null;
  const label = plainText(link).trim();
  if (!isDegradedLoneLabel(label, link.url, entry)) return null;
  const surface = normalizeRichSurface({
    version: 2,
    type: "news",
    state: "ready",
    items: [resultItem(link, entry)]
  });
  if (!surface) return null;
  children.splice(index, 1, richNode(surface, children[index]));
  return 1;
}

function newsSurface(links, entries) {
  if (links.length > MAX_ENRICHED_ITEMS) return null;
  const items = [];
  const labels = [];
  for (const link of links) {
    const entry = entries.get(String(link.url || ""));
    if (!entry) return null;
    labels.push({ label: plainText(link).trim(), url: link.url, entry });
    items.push(resultItem(link, entry));
  }
  const identical = labels.every(({ label }) => normalized(label) === normalized(labels[0].label));
  const sourceLike = labels.every(({ label, url, entry }) => isSourceLabel(label, url, entry));
  if (!identical && !sourceLike) return null;
  return normalizeRichSurface({ version: 2, type: "news", state: "ready", items });
}

function normalized(value) {
  return String(value || "").trim().toLowerCase();
}

function isSourceLabel(label, url, entry) {
  const value = normalized(label);
  if (!value) return false;
  return value === normalized(entry.source) || value === normalized(hostLabel(String(url || "")));
}

function isDegradedLoneLabel(label, url, entry) {
  if (isSourceLabel(label, url, entry)) return true;
  const value = normalized(label);
  if (/^https?:\/\//.test(value)) return true;
  const title = normalized(entry.title);
  return Boolean(title && value.length >= 8 && (title.startsWith(value) || value.startsWith(title)));
}

function resultItem(link, entry) {
  const item = {
    title: entry.title,
    url: String(link.url || "")
  };
  for (const key of ["source", "date", "snippet"]) {
    if (typeof entry[key] === "string" && entry[key].trim()) item[key] = entry[key];
  }
  if (typeof entry.image === "string" && entry.image) {
    item.image = { src: entry.image, alt: entry.title };
  }
  if (typeof entry.favicon === "string" && entry.favicon) {
    item.favicon = { src: entry.favicon, alt: item.source || "" };
  }
  return item;
}

function richNode(surface, sourceNode) {
  return { type: "scopyRich", surface, position: sourceNode?.position };
}

function soleLink(node) {
  if (node?.type !== "paragraph" || !Array.isArray(node.children)) return null;
  let link = null;
  for (const child of node.children) {
    if (child?.type === "link") {
      if (link) return null;
      link = child;
      continue;
    }
    if (child?.type === "text" && /^\s*$/.test(String(child.value || ""))) continue;
    return null;
  }
  return link;
}

function plainText(node) {
  if (!node) return "";
  if (node.type === "text" || node.type === "inlineCode") return String(node.value || "");
  return Array.isArray(node.children) ? node.children.map(plainText).join("") : "";
}

function visitParents(node, visitor) {
  if (!node || !Array.isArray(node.children)) return;
  visitor(node);
  for (const child of node.children) {
    visitParents(child, visitor);
  }
}
