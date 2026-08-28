export function remarkLiteralHTML() {
  return function transformer(tree) {
    literalizeHTMLNodes(tree);
  };
}

function literalizeHTMLNodes(node) {
  if (!node || !Array.isArray(node.children)) {
    return;
  }

  node.children = node.children.map((child) => {
    if (child && child.type === "html") {
      return {
        type: "text",
        value: String(child.value || ""),
        position: child.position
      };
    }
    literalizeHTMLNodes(child);
    return child;
  });
}
