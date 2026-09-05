import fileAssets from "./codexFileIconAssets.json" with { type: "json" };
import globeAssets from "./codexGlobeAssets.json" with { type: "json" };
import pluginAssets from "./codexPluginIconAssets.json" with { type: "json" };

// Static trusted artwork, inserted after sanitization. Never accept authored SVG.
// Keep geometry and paint unchanged; only scope IDs to this render's occurrence.
export function codexFileIcon(kind, occurrence) {
  const key = kind === "yaml" ? "file" : kind;
  const source = Object.hasOwn(fileAssets.icons, key) ? fileAssets.icons[key] : fileAssets.icons.file;
  return decorate(source, `scopy-codex-icon--${kind}`, `scopy-file-${occurrence}`);
}

export function codexGlobeIcon(size = 16) {
  return decorate(globeAssets.icons[size === 12 ? "12" : "16"], "scopy-icon--globe", "scopy-globe");
}

export function codexPluginIcon(href, occurrence) {
  const identifier = String(href).replace(/^(?:plugin:(?:\/\/)?|app:\/\/)/, "").split(/[/?#@]/, 1)[0]
    .trim().toLowerCase().split(/[^a-z0-9]+/g).filter(Boolean).join("-");
  const key = [identifier, identifier.replace(/^connector-/, ""), identifier.replace(/^connector-/, "").replace(/-mcp-server$/, "")]
    .find((name) => Object.hasOwn(pluginAssets.icons, name));
  return key ? decorate(pluginAssets.icons[key], `scopy-codex-plugin--${key}`, `scopy-plugin-${occurrence}`) : codexGlobeIcon();
}

function decorate(source, className, prefix) {
  const icon = JSON.parse(JSON.stringify(source));
  const ids = new Map();
  walk(icon, (node) => {
    if (node.properties?.id) ids.set(node.properties.id, `${prefix}-${node.properties.id}`);
  });
  walk(icon, (node) => {
    for (const [key, value] of Object.entries(node.properties || {})) {
      if (typeof value !== "string") continue;
      if (key === "id") node.properties[key] = ids.get(value);
      else node.properties[key] = value.replace(/url\(#([^)]*)\)/g, (match, id) => ids.has(id) ? `url(#${ids.get(id)})` : match);
    }
  });
  icon.properties = {
    className: ["scopy-icon", className], ...icon.properties,
    ariaHidden: "true", focusable: "false"
  };
  return icon;
}

function walk(node, visit) {
  visit(node);
  for (const child of node.children || []) walk(child, visit);
}

const extensions = Object.fromEntries(Object.entries({
  typescript: "ts", react: "tsx jsx", javascript: "js mjs cjs hs", python: "py",
  java: "java", rust: "rs", php: "php", css: "css scss less sass",
  cplusplus: "cpp cxx cc c hpp hh h", code: "rb go kt swift m mm cs sql",
  json: "json jsonc", document: "md mdx markdown mkd mdown xml env dotenv gitignore lock txt rtf",
  html: "html htm", yaml: "yaml yml", toml: "toml", spreadsheet: "csv tsv xls xlsm xlsx",
  artifactDocument: "doc docx", notebook: "ipynb", presentation: "ppt pptx",
  shell: "sh bash zsh fish ps1", terminal: "dockerfile", image: "png jpg jpeg gif webp bmp svg ico heic heif tif tiff avif",
  build: "build bazel bzl ninja gradle mk makefile", hashes: "sha sha1 sha256 md5 checksum sum",
  pdf: "pdf", folder: "zip gz tgz tar",
  // Codex attachment artwork applied to Scopy's local media links as requested.
  video: "mp4 mov m4v webm avi mkv mpg mpeg", audio: "mp3 m4a wav aiff aif flac ogg opus aac"
}).flatMap(([kind, values]) => values.split(" ").map((value) => [value, kind])));

export function localFileKind(value) {
  let clean = String(value).split(/[?#]/, 1)[0].replace(/:\d+(?::\d+)?$/, "");
  try { clean = decodeURIComponent(clean); } catch { /* Keep malformed paths inert under navigation policy. */ }
  if (/[\\/]$/.test(clean)) return "folder";
  const name = clean.toLowerCase().split(/[\\/]/).at(-1);
  if (name === "skill.md") return "skill";
  const extension = name.split(".").at(-1);
  return Object.hasOwn(extensions, extension) ? extensions[extension] : "file";
}
