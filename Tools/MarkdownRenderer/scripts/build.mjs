import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const repoRoot = resolve(root, "../..");
const outfile = resolve(repoRoot, "Scopy/Resources/MarkdownPreview/contrib/scopy-unified-renderer.iife.js");

await mkdir(dirname(outfile), { recursive: true });
await esbuild.build({
  entryPoints: [resolve(root, "src/index.js")],
  outfile,
  bundle: true,
  format: "iife",
  target: ["safari16"],
  minify: true,
  legalComments: "none"
});

const bundled = await readFile(outfile, "utf8");
const normalized = bundled.replace(/[ \t]+$/gm, "");
if (normalized !== bundled) {
  await writeFile(outfile, normalized, "utf8");
}
const bytes = await readFile(outfile);
const hash = createHash("sha256").update(bytes).digest("hex");
await writeFile(`${outfile}.sha256`, `${hash}\n`, "utf8");
console.log(`wrote ${outfile}`);
console.log(`sha256 ${hash}`);
