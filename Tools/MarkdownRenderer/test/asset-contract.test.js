import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import {
  defaultAssetRoot,
  katexCSSRelativePath,
  loadLockedKatexAssets,
  manifestRelativePath,
  rendererRelativePath,
  rendererSidecarRelativePath,
  sha256,
  synchronizeReleaseAssets,
  verifyReleaseAssets
} from "../scripts/asset-contract.mjs";

async function withTemporaryAssetRoot(run) {
  const assetRoot = await mkdtemp(join(tmpdir(), "scopy-markdown-assets-"));
  try {
    await run(assetRoot);
  } finally {
    await rm(assetRoot, { recursive: true, force: true });
  }
}

test("synchronizes one exact renderer, CSS, font, sidecar, and manifest set", async () => {
  await withTemporaryAssetRoot(async (assetRoot) => {
    const rendererBytes = Buffer.from("window.__fixtureRenderer = true;\n");
    const { manifest } = await synchronizeReleaseAssets({
      assetRoot,
      rendererBytes
    });
    const katexAssets = await loadLockedKatexAssets();

    assert.equal(manifest.katex.version, katexAssets.version);
    assert.equal(manifest.katex.fonts.length, katexAssets.fonts.length);
    assert.equal(manifest.renderer.sha256, sha256(rendererBytes));
    assert.equal(
      await readFile(join(assetRoot, rendererSidecarRelativePath), "utf8"),
      `${sha256(rendererBytes)}\n`
    );
    assert.deepEqual(
      await readFile(join(assetRoot, katexCSSRelativePath)),
      katexAssets.cssBytes
    );

    const verification = await verifyReleaseAssets({
      assetRoot,
      expectedRendererBytes: rendererBytes
    });
    assert.deepEqual(verification.failures, []);
  });
});

test("reports package, sidecar, manifest, and font-set drift precisely", async () => {
  await withTemporaryAssetRoot(async (assetRoot) => {
    const rendererBytes = Buffer.from("window.__fixtureRenderer = true;\n");
    await synchronizeReleaseAssets({ assetRoot, rendererBytes });

    await writeFile(join(assetRoot, katexCSSRelativePath), "stale css\n");
    await writeFile(join(assetRoot, rendererSidecarRelativePath), "stale\n");
    await writeFile(join(assetRoot, "fonts/Unexpected.woff2"), "stale\n");
    const verification = await verifyReleaseAssets({
      assetRoot,
      verifySourceBundle: false
    });
    const codes = new Set(verification.failures.map(({ code }) => code));

    assert.ok(codes.has("PACKAGE_ASSET_DRIFT"));
    assert.ok(codes.has("RENDERER_SIDECAR_DRIFT"));
    assert.ok(codes.has("KATEX_FONT_SET_DRIFT"));

    await writeFile(join(assetRoot, manifestRelativePath), "{}\n");
    const manifestVerification = await verifyReleaseAssets({
      assetRoot,
      verifySourceBundle: false
    });
    assert.ok(
      manifestVerification.failures.some(
        ({ code }) => code === "ASSET_MANIFEST_DRIFT"
      )
    );
  });
});

test("reports source bundle drift separately from checked-in asset drift", async () => {
  await withTemporaryAssetRoot(async (assetRoot) => {
    const checkedInRenderer = Buffer.from("window.__oldRenderer = true;\n");
    const sourceRenderer = Buffer.from("window.__newRenderer = true;\n");
    await synchronizeReleaseAssets({
      assetRoot,
      rendererBytes: checkedInRenderer
    });

    const verification = await verifyReleaseAssets({
      assetRoot,
      expectedRendererBytes: sourceRenderer
    });
    assert.deepEqual(
      verification.failures.map(({ code }) => code),
      ["RENDERER_SOURCE_DRIFT"]
    );
  });
});

test("checked-in package assets and manifest match the lockfile", async () => {
  const verification = await verifyReleaseAssets({
    assetRoot: defaultAssetRoot,
    verifySourceBundle: false
  });
  assert.deepEqual(verification.failures, []);

  const manifest = JSON.parse(
    await readFile(join(defaultAssetRoot, manifestRelativePath), "utf8")
  );
  assert.equal(manifest.renderer.path, rendererRelativePath);
});
