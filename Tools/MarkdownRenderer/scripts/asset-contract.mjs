import { createHash } from "node:crypto";
import {
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile
} from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));

export const markdownRendererRoot = resolve(scriptDirectory, "..");
export const repositoryRoot = resolve(markdownRendererRoot, "../..");
export const defaultAssetRoot = resolve(
  repositoryRoot,
  "Scopy/Resources/MarkdownPreview"
);
export const manifestRelativePath = "asset-manifest.json";
export const rendererRelativePath =
  "contrib/scopy-unified-renderer.iife.js";
export const rendererSidecarRelativePath = `${rendererRelativePath}.sha256`;
export const katexCSSRelativePath = "katex.min.css";
export const katexFontsRelativePath = "fonts";

const packageLockPath = resolve(markdownRendererRoot, "package-lock.json");
const installedKatexRoot = resolve(
  markdownRendererRoot,
  "node_modules/katex"
);
const rendererEntrypoint = resolve(markdownRendererRoot, "src/index.js");

const bundleConfiguration = Object.freeze({
  entrypoint: "Tools/MarkdownRenderer/src/index.js",
  format: "iife",
  target: ["safari16"],
  minify: true,
  legalComments: "none"
});

function normalizeBundle(bytes) {
  const source = Buffer.from(bytes).toString("utf8");
  return Buffer.from(source.replace(/[ \t]+$/gm, ""), "utf8");
}

export function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function readJSON(path, label) {
  let bytes;
  try {
    bytes = await readFile(path, "utf8");
  } catch (error) {
    throw new Error(`${label} is unreadable at ${path}: ${error.message}`);
  }
  try {
    return JSON.parse(bytes);
  } catch (error) {
    throw new Error(`${label} is invalid JSON at ${path}: ${error.message}`);
  }
}

export async function resolveLockedKatex() {
  const lockfile = await readJSON(packageLockPath, "package-lock.json");
  const rootPackage = lockfile.packages?.[""];
  const lockedPackage = lockfile.packages?.["node_modules/katex"];
  if (!rootPackage?.dependencies?.katex) {
    throw new Error("package-lock.json does not declare the root katex dependency");
  }
  if (!lockedPackage?.version || !lockedPackage?.integrity) {
    throw new Error(
      "package-lock.json does not contain an exact node_modules/katex version and integrity"
    );
  }
  return {
    requested: rootPackage.dependencies.katex,
    version: lockedPackage.version,
    integrity: lockedPackage.integrity
  };
}

function referencedFontPaths(cssBytes) {
  const css = Buffer.from(cssBytes).toString("utf8");
  const matches = css.matchAll(/url\((?:["']?)(fonts\/[^)'"?]+)(?:["']?)\)/g);
  const paths = [...new Set([...matches].map((match) => match[1]))].sort();
  if (paths.length === 0) {
    throw new Error("KaTeX CSS does not reference any bundled fonts");
  }
  for (const path of paths) {
    if (!/^fonts\/KaTeX_[A-Za-z0-9-]+\.(?:ttf|woff|woff2)$/.test(path)) {
      throw new Error(`KaTeX CSS contains an unexpected font path: ${path}`);
    }
  }
  return paths;
}

export async function loadLockedKatexAssets() {
  const locked = await resolveLockedKatex();
  const installedPackage = await readJSON(
    resolve(installedKatexRoot, "package.json"),
    "installed katex package.json"
  );
  if (installedPackage.version !== locked.version) {
    throw new Error(
      `installed katex ${installedPackage.version ?? "unknown"} does not match package-lock.json ${locked.version}; run npm ci`
    );
  }

  const cssSourcePath = resolve(installedKatexRoot, "dist/katex.min.css");
  const cssBytes = await readFile(cssSourcePath);
  const fontPaths = referencedFontPaths(cssBytes);
  const fonts = [];
  for (const path of fontPaths) {
    const sourcePath = resolve(installedKatexRoot, "dist", path);
    if (!sourcePath.startsWith(`${resolve(installedKatexRoot, "dist")}${sep}`)) {
      throw new Error(`refusing unsafe KaTeX font path: ${path}`);
    }
    fonts.push({ path, bytes: await readFile(sourcePath) });
  }

  const installedFontEntries = (
    await readdir(resolve(installedKatexRoot, "dist/fonts"), {
      withFileTypes: true
    })
  )
    .filter((entry) => entry.isFile())
    .map((entry) => `fonts/${entry.name}`)
    .sort();
  if (JSON.stringify(installedFontEntries) !== JSON.stringify(fontPaths)) {
    throw new Error(
      "KaTeX dist/fonts and the font URLs in katex.min.css are not the same exact set"
    );
  }

  return {
    ...locked,
    cssBytes,
    fonts
  };
}

export async function buildRendererBytes() {
  const result = await esbuild.build({
    entryPoints: [rendererEntrypoint],
    bundle: true,
    format: bundleConfiguration.format,
    target: bundleConfiguration.target,
    minify: bundleConfiguration.minify,
    legalComments: bundleConfiguration.legalComments,
    outfile: resolve(markdownRendererRoot, ".asset-verification/renderer.js"),
    write: false
  });
  if (result.outputFiles?.length !== 1) {
    throw new Error(
      `esbuild produced ${result.outputFiles?.length ?? 0} outputs; expected exactly one renderer bundle`
    );
  }
  return normalizeBundle(result.outputFiles[0].contents);
}

export function createAssetManifest(rendererBytes, katexAssets) {
  return {
    schemaVersion: 1,
    renderer: {
      path: rendererRelativePath,
      sidecarPath: rendererSidecarRelativePath,
      sha256: sha256(rendererBytes),
      bytes: rendererBytes.length,
      build: bundleConfiguration
    },
    katex: {
      package: "katex",
      requested: katexAssets.requested,
      version: katexAssets.version,
      lockfileIntegrity: katexAssets.integrity,
      css: {
        path: katexCSSRelativePath,
        sha256: sha256(katexAssets.cssBytes),
        bytes: katexAssets.cssBytes.length
      },
      fonts: katexAssets.fonts.map(({ path, bytes }) => ({
        path,
        sha256: sha256(bytes),
        bytes: bytes.length
      }))
    }
  };
}

export function serializeAssetManifest(manifest) {
  return `${JSON.stringify(manifest, null, 2)}\n`;
}

async function atomicWrite(path, bytes) {
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = join(
    dirname(path),
    `.${basename(path)}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`
  );
  try {
    await writeFile(temporaryPath, bytes);
    await rename(temporaryPath, path);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

async function synchronizeFonts(assetRoot, fonts) {
  const destinationRoot = resolve(assetRoot, katexFontsRelativePath);
  await mkdir(destinationRoot, { recursive: true });
  const expectedNames = new Set();
  for (const { path, bytes } of fonts) {
    const name = basename(path);
    expectedNames.add(name);
    await atomicWrite(resolve(destinationRoot, name), bytes);
  }

  const removed = [];
  for (const entry of await readdir(destinationRoot, { withFileTypes: true })) {
    if (entry.isFile() && expectedNames.has(entry.name)) {
      continue;
    }
    const target = resolve(destinationRoot, entry.name);
    if (dirname(target) !== destinationRoot) {
      throw new Error(`refusing unsafe font cleanup path: ${target}`);
    }
    await rm(target, { recursive: true, force: true });
    removed.push(entry.name);
  }
  return removed.sort();
}

export async function synchronizeReleaseAssets({
  assetRoot = defaultAssetRoot,
  rendererBytes,
  writeRenderer = true
} = {}) {
  const resolvedAssetRoot = resolve(assetRoot);
  if (!rendererBytes) {
    rendererBytes = await readFile(
      resolve(resolvedAssetRoot, rendererRelativePath)
    );
  }
  rendererBytes = Buffer.from(rendererBytes);
  const katexAssets = await loadLockedKatexAssets();

  if (writeRenderer) {
    await atomicWrite(
      resolve(resolvedAssetRoot, rendererRelativePath),
      rendererBytes
    );
  }
  await atomicWrite(
    resolve(resolvedAssetRoot, rendererSidecarRelativePath),
    `${sha256(rendererBytes)}\n`
  );
  await atomicWrite(
    resolve(resolvedAssetRoot, katexCSSRelativePath),
    katexAssets.cssBytes
  );
  const removedFonts = await synchronizeFonts(
    resolvedAssetRoot,
    katexAssets.fonts
  );

  const manifest = createAssetManifest(rendererBytes, katexAssets);
  // The manifest is committed last. A partial update cannot verify as a complete
  // release asset set, even if an earlier process was interrupted.
  await atomicWrite(
    resolve(resolvedAssetRoot, manifestRelativePath),
    serializeAssetManifest(manifest)
  );
  return { manifest, removedFonts };
}

function addFailure(failures, code, message) {
  failures.push({ code, message });
}

async function readAsset(assetRoot, relativePath, failures) {
  const path = resolve(assetRoot, relativePath);
  try {
    return await readFile(path);
  } catch (error) {
    addFailure(
      failures,
      "MISSING_ASSET",
      `${relativePath} is unreadable: ${error.message}`
    );
    return null;
  }
}

function compareBytes(failures, label, actual, expected) {
  if (actual && !actual.equals(expected)) {
    addFailure(
      failures,
      "PACKAGE_ASSET_DRIFT",
      `${label} differs from the exact katex package locked by package-lock.json`
    );
  }
}

export async function verifyReleaseAssets({
  assetRoot = defaultAssetRoot,
  verifySourceBundle = true,
  expectedRendererBytes
} = {}) {
  const resolvedAssetRoot = resolve(assetRoot);
  const failures = [];
  let katexAssets;
  try {
    katexAssets = await loadLockedKatexAssets();
  } catch (error) {
    addFailure(failures, "KATEX_PACKAGE_MISMATCH", error.message);
    return { assetRoot: resolvedAssetRoot, failures };
  }

  const rendererBytes = await readAsset(
    resolvedAssetRoot,
    rendererRelativePath,
    failures
  );
  const sidecarBytes = await readAsset(
    resolvedAssetRoot,
    rendererSidecarRelativePath,
    failures
  );
  const cssBytes = await readAsset(
    resolvedAssetRoot,
    katexCSSRelativePath,
    failures
  );
  const manifestBytes = await readAsset(
    resolvedAssetRoot,
    manifestRelativePath,
    failures
  );

  if (rendererBytes && sidecarBytes) {
    const expectedSidecar = `${sha256(rendererBytes)}\n`;
    if (sidecarBytes.toString("utf8") !== expectedSidecar) {
      addFailure(
        failures,
        "RENDERER_SIDECAR_DRIFT",
        `${rendererSidecarRelativePath} does not contain the checked-in renderer SHA256`
      );
    }
  }
  if (cssBytes) {
    compareBytes(
      failures,
      katexCSSRelativePath,
      cssBytes,
      katexAssets.cssBytes
    );
  }

  const expectedFontPaths = katexAssets.fonts.map(({ path }) => path).sort();
  const actualFontRoot = resolve(resolvedAssetRoot, katexFontsRelativePath);
  let actualFontPaths = [];
  try {
    actualFontPaths = (
      await readdir(actualFontRoot, { withFileTypes: true })
    )
      .map(
        (entry) =>
          `${katexFontsRelativePath}/${entry.name}${entry.isDirectory() ? "/" : ""}`
      )
      .sort();
  } catch (error) {
    addFailure(
      failures,
      "MISSING_ASSET",
      `${katexFontsRelativePath} is unreadable: ${error.message}`
    );
  }
  if (JSON.stringify(actualFontPaths) !== JSON.stringify(expectedFontPaths)) {
    addFailure(
      failures,
      "KATEX_FONT_SET_DRIFT",
      `checked-in fonts do not match the exact locked katex set (${actualFontPaths.length}/${expectedFontPaths.length})`
    );
  }
  for (const font of katexAssets.fonts) {
    const actual = await readAsset(resolvedAssetRoot, font.path, failures);
    compareBytes(failures, font.path, actual, font.bytes);
  }

  if (rendererBytes && manifestBytes) {
    const expectedManifest = serializeAssetManifest(
      createAssetManifest(rendererBytes, katexAssets)
    );
    if (manifestBytes.toString("utf8") !== expectedManifest) {
      addFailure(
        failures,
        "ASSET_MANIFEST_DRIFT",
        `${manifestRelativePath} does not describe the checked-in renderer and exact locked katex assets`
      );
    }
  }

  if (verifySourceBundle && rendererBytes) {
    let sourceBytes = expectedRendererBytes;
    try {
      sourceBytes ??= await buildRendererBytes();
    } catch (error) {
      addFailure(
        failures,
        "RENDERER_BUILD_FAILED",
        `could not build the renderer source for comparison: ${error.message}`
      );
    }
    const checkedInHash = sha256(normalizeBundle(rendererBytes));
    const sourceHash = sourceBytes
      ? sha256(normalizeBundle(sourceBytes))
      : null;
    if (sourceHash && sourceHash !== checkedInHash) {
      addFailure(
        failures,
        "RENDERER_SOURCE_DRIFT",
        `checked-in renderer ${checkedInHash} differs from source build ${sourceHash}; run npm run build after renderer source changes`
      );
    }
  }

  return {
    assetRoot: resolvedAssetRoot,
    failures,
    rendererSHA256: rendererBytes
      ? sha256(normalizeBundle(rendererBytes))
      : null,
    katexVersion: katexAssets.version,
    fontCount: katexAssets.fonts.length
  };
}

export function formatVerification(result) {
  if (result.failures.length === 0) {
    return [
      `MarkdownPreview assets verified: ${result.assetRoot}`,
      `renderer sha256 ${result.rendererSHA256}`,
      `katex ${result.katexVersion}, fonts ${result.fontCount}`
    ].join("\n");
  }
  return [
    `MarkdownPreview asset verification FAILED: ${result.assetRoot}`,
    ...result.failures.map(
      (failure) => `[${failure.code}] ${failure.message}`
    )
  ].join("\n");
}
