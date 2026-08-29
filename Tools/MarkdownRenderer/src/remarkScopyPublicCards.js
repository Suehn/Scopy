import { normalizeRichSurface } from "./remarkScopyRich.js";

// Public-copy presentation adapters. ChatGPT's Copy action strips card payloads, so a real
// public copy carries only visible prose. These adapters promote exactly three closed
// paragraph shapes whose visible fields are complete enough for an honest card:
//
//   1. a paragraph that is one YouTube link            -> video card (title = link text)
//   2. a link-only paragraph followed by a price-only  -> product card
//      paragraph
//   3. a paragraph of "Name / link / Address: ... /    -> entity (place) card
//      Phone: ... / Hours: ..." lines
//
// Every candidate passes through the same strict v2 `normalizeRichSurface` authority; a
// shape that fails validation stays ordinary prose. Nothing here fetches, guesses hidden
// metadata, or widens beyond these exact shapes.

const VIDEO_HOSTS = new Set([
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  "youtu.be"
]);
const PRICE_PATTERN = /^[$€£¥]\s?\d[\d,.]*$/u;
const DETAIL_LABELS = Object.freeze({
  "Address": "address",
  "Phone": "phone",
  "Hours": "hours"
});

export function remarkScopyPublicCards() {
  return function transformer(tree) {
    visitParents(tree, (parent) => {
      if (!parent || !Array.isArray(parent.children)) return;
      const children = parent.children;
      for (let index = 0; index < children.length;) {
        const advance =
          adaptEntity(children, index) ??
          adaptProduct(children, index) ??
          adaptVideo(children, index) ??
          1;
        index += advance;
      }
    });
  };
}

function adaptVideo(children, index) {
  const link = soleLink(children[index]);
  if (!link || !isVideoURL(link.url)) return null;
  const title = plainText(link).trim();
  if (!title) return null;
  const surface = normalizeRichSurface({
    version: 2,
    type: "video",
    state: "ready",
    title,
    url: String(link.url)
  });
  if (!surface) return null;
  children.splice(index, 1, richNode(surface, children[index]));
  return 1;
}

function adaptProduct(children, index) {
  // A copied product degrades to either a link-only paragraph or a `### [title](url)`
  // heading, immediately followed by a price-only paragraph.
  const holder = children[index];
  const link = soleLink(holder) ?? (holder?.type === "heading" ? soleLink({ ...holder, type: "paragraph" }) : null);
  if (!link || isVideoURL(link.url)) return null;
  const price = solePriceText(children[index + 1]);
  if (!price) return null;
  const title = plainText(link).trim();
  if (!title) return null;
  const surface = normalizeRichSurface({
    version: 2,
    type: "product",
    state: "ready",
    product: { title, url: String(link.url), price }
  });
  if (!surface) return null;
  children.splice(index, 2, richNode(surface, children[index]));
  return 1;
}

function adaptEntity(children, index) {
  const lines = breakSeparatedLines(children[index]);
  if (!lines || lines.length < 3) return null;
  const [nameLine, linkLine, ...detailLines] = lines;
  const name = soleText(nameLine);
  const link = lines.length >= 2 && linkLine.length === 1 && linkLine[0].type === "link"
    ? linkLine[0]
    : null;
  if (!name || !link) return null;

  const details = {};
  for (const line of detailLines) {
    const value = soleText(line);
    const match = value ? /^(Address|Phone|Hours):\s+(\S.*)$/.exec(value) : null;
    if (!match) return null;
    const key = DETAIL_LABELS[match[1]];
    if (details[key] !== undefined) return null;
    details[key] = match[2];
  }
  if (!details.address) return null;

  const surface = normalizeRichSurface({
    version: 2,
    type: "entity",
    state: "ready",
    name,
    url: String(link.url),
    ...details
  });
  if (!surface) return null;

  // The copy usually repeats the bare place name as its own paragraph directly above the
  // detail block; fold that duplicate into the card instead of leaving stray prose.
  const previous = children[index - 1];
  const duplicateName = previous && soleTextParagraph(previous) === name;
  if (duplicateName) {
    children.splice(index - 1, 2, richNode(surface, previous));
    return 0;
  }
  children.splice(index, 1, richNode(surface, children[index]));
  return 1;
}

function richNode(surface, sourceNode) {
  return { type: "scopyRich", surface, position: sourceNode?.position };
}

function isVideoURL(url) {
  try {
    return VIDEO_HOSTS.has(new URL(String(url || "")).hostname.toLowerCase());
  } catch {
    return false;
  }
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

function solePriceText(node) {
  if (node?.type !== "paragraph" || !Array.isArray(node.children)) return null;
  const meaningful = node.children.filter(
    (child) => !(child?.type === "text" && /^\s*$/.test(String(child.value || "")))
  );
  if (meaningful.length !== 1) return null;
  const inner = meaningful[0].type === "emphasis" || meaningful[0].type === "strong"
    ? meaningful[0]
    : { children: [meaningful[0]] };
  const value = plainText(inner).trim();
  return PRICE_PATTERN.test(value) ? value : null;
}

function soleTextParagraph(node) {
  if (node?.type !== "paragraph" || !Array.isArray(node.children)) return null;
  return soleText(node.children);
}

function soleText(line) {
  if (!Array.isArray(line) || line.length === 0) return null;
  if (!line.every((child) => child?.type === "text")) return null;
  const value = line.map((child) => String(child.value || "")).join("").trim();
  return value || null;
}

function breakSeparatedLines(node) {
  if (node?.type !== "paragraph" || !Array.isArray(node.children)) return null;
  const lines = [[]];
  for (const child of node.children) {
    if (child?.type === "break") {
      lines.push([]);
      continue;
    }
    lines[lines.length - 1].push(child);
  }
  return lines.map((line) =>
    line.filter((child) => !(child?.type === "text" && /^\s*$/.test(String(child.value || "")))))
    .filter((line) => line.length > 0);
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
