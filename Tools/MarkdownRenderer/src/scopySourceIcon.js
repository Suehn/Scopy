import { codexGlobeIcon } from "./scopyCodexIcons.js";
import { isValidExternalHTTPURL } from "./scopyExternalURLPolicy.js";
import { bundledFaviconAssetForHost, bundledImagePath } from "./scopyLocalImageAssets.js";

// One offline identity rule for links, citations and result cards. Labels never select
// a brand; only a validated destination's exact host can select bundled artwork.
export function scopySourceIcon(url, classNames, faviconClass) {
  const host = isValidExternalHTTPURL(url) ? new URL(url).hostname.toLowerCase() : null;
  const path = bundledImagePath(bundledFaviconAssetForHost(host));
  if (path) {
    return {
      type: "element", tagName: "img",
      properties: { src: path, alt: "", className: [...classNames, ...(faviconClass ? [faviconClass] : [])] },
      children: []
    };
  }
  const icon = codexGlobeIcon(classNames.includes("scopy-source-citation-origin-icon") ? 12 : 16);
  icon.properties.className.push(...classNames);
  if (host) {
    const destination = new URL(url);
    if (!destination.port && /^[a-z0-9.-]+$/i.test(host)) {
      icon.properties.dataScopySourceIcon = `scopy-source-icon://${host}/${destination.protocol.slice(0, -1)}`;
    }
  }
  return icon;
}

// Called by the shared image-readiness path, before either preview reveal or PNG.
// A damaged frozen favicon must not expand into the ordinary image-error label.
export function replaceFailedSourceIcon(image) {
  const classes = ["scopy-link-origin-icon", "scopy-source-citation-origin-icon", "scopy-rich-origin-icon"];
  const matched = classes.filter((name) => image?.classList?.contains(name));
  if (!matched.length || !image.parentNode) return false;
  const icon = codexGlobeIcon(matched.includes("scopy-source-citation-origin-icon") ? 12 : 16);
  const doc = image.ownerDocument;
  const namespace = "http://www.w3.org/2000/svg";
  const svg = doc.createElementNS(namespace, "svg");
  svg.setAttribute("class", [...icon.properties.className, ...matched].join(" "));
  svg.setAttribute("viewBox", icon.properties.viewBox);
  svg.setAttribute("width", "16");
  svg.setAttribute("height", "16");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.setAttribute("data-scopy-image-state", "error");
  const path = doc.createElementNS(namespace, "path");
  path.setAttribute("d", icon.children[0].properties.d);
  path.setAttribute("fill", "currentColor");
  path.setAttribute("fill-rule", "evenodd");
  path.setAttribute("clip-rule", "evenodd");
  svg.appendChild(path);
  image.parentNode.replaceChild(svg, image);
  return true;
}

// Run after sanitization. Only our source-icon nodes can become native image requests;
// authored images never gain access to this image-only origin service.
export function rehypeScopyNativeSourceIcons({ enabled }) {
  return (tree) => {
    const origins = new Set();
    let count = 0;
    function visit(node) {
      const source = node?.properties?.dataScopySourceIcon;
      if (source) {
        delete node.properties.dataScopySourceIcon;
        if (enabled && count < 256 && (origins.has(source) || origins.size < 24)) {
          origins.add(source);
          count += 1;
          node.tagName = "img";
          node.properties = { src: source, alt: "", className: node.properties.className.filter(name => name !== "scopy-icon--globe"),
            dataScopyNativeSourceIcon: "true" };
          node.children = [];
        }
      }
      for (const child of node?.children || []) visit(child);
    }
    visit(tree);
  };
}
