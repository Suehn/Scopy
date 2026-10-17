import { bundledImageAssetForExactRemoteURL } from "./scopyLocalImageAssets.js";
import { normalizeRichSurface } from "./remarkScopyRich.js";

export function remarkScopyImageGroups() {
  return function transformer(tree) {
    visitParents(tree, (parent) => {
      if (!parent || !Array.isArray(parent.children)) return;
      const children = parent.children;
      for (let index = 0; index < children.length;) {
        if (!imagesFromParagraph(children[index])) {
          index += 1;
          continue;
        }
        let end = index + 1;
        while (end < children.length && imagesFromParagraph(children[end])) {
          end += 1;
        }
        const paragraphs = children.slice(index, end);
        const images = paragraphs.flatMap((paragraph) => imagesFromParagraph(paragraph));
        if (images.length < 2) {
          index = end;
          continue;
        }
        const replacements = [];
        let valid = true;
        for (let start = 0; start < images.length;) {
          const remaining = images.length - start;
          const count = Math.min(12, remaining);
          const surface = normalizeRichSurface({
            version: 2,
            type: "image_group",
            layout: count === 2 ? "search" : "carousel",
            images: images.slice(start, start + count).map(groupedImage)
          });
          if (!surface) {
            valid = false;
            break;
          }
          if (remaining === 1) {
            replacements.push({
              type: "paragraph",
              children: [{
                type: "image",
                url: images[start].src,
                alt: images[start].alt,
                title: images[start].title
              }]
            });
            start += 1;
            continue;
          }
          replacements.push({
            type: "scopyImageGroup",
            surface
          });
          start += count;
        }
        // A rejected batch, including a lone tail, keeps the entire original run intact.
        if (!valid) {
          index = end;
          continue;
        }
        children.splice(index, end - index, ...replacements);
        index += replacements.length;
      }
    });
  };
}

function groupedImage(image) {
  const asset = bundledImageAssetForExactRemoteURL(image.src);
  if (!asset) return image;
  return {
    asset,
    alt: image.alt,
    ...(image.title === undefined ? {} : { title: image.title })
  };
}

function imagesFromParagraph(node) {
  if (node?.type !== "paragraph" || !Array.isArray(node.children)) return null;
  const images = [];
  for (const child of node.children) {
    if (child?.type === "image") {
      images.push({
        src: String(child.url || ""),
        alt: String(child.alt || ""),
        title: child.title == null ? undefined : String(child.title)
      });
      continue;
    }
    if (child?.type === "break") continue;
    if (child?.type === "text" && /^\s*$/.test(String(child.value || ""))) continue;
    return null;
  }
  return images.length > 0 ? images : null;
}

function visitParents(node, visitor) {
  if (!node || !Array.isArray(node.children)) return;
  visitor(node);
  for (const child of node.children) {
    visitParents(child, visitor);
  }
}
