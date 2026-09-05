import { scopyIcon } from "./scopyIcons.js";
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
  const icon = scopyIcon("globe");
  icon.properties.className.push(...classNames);
  return icon;
}

// Called by the shared image-readiness path, before either preview reveal or PNG.
// A damaged frozen favicon must not expand into the ordinary image-error label.
export function replaceFailedSourceIcon(image) {
  const classes = ["scopy-link-origin-icon", "scopy-source-citation-origin-icon", "scopy-rich-origin-icon"];
  const matched = classes.filter((name) => image?.classList?.contains(name));
  if (!matched.length || !image.parentNode) return false;
  const icon = scopyIcon("globe");
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
  svg.appendChild(path);
  image.parentNode.replaceChild(svg, image);
  return true;
}
