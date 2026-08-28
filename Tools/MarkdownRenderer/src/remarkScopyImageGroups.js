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
        for (let start = 0; start < images.length;) {
          const remaining = images.length - start;
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
          const count = Math.min(12, remaining);
          replacements.push({ type: "scopyImageGroup", images: images.slice(start, start + count) });
          start += count;
        }
        children.splice(index, end - index, ...replacements);
        index += replacements.length;
      }
    });
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
