import { resolve } from "node:path";
import {
  defaultAssetRoot,
  formatVerification,
  verifyReleaseAssets
} from "./asset-contract.mjs";

function usage() {
  return [
    "Usage: node scripts/verify-assets.mjs [options]",
    "",
    "Options:",
    "  --asset-root PATH       Verify this MarkdownPreview directory",
    "  --skip-source-bundle    Skip rebuilding src/index.js for comparison",
    "  --help                  Show this help"
  ].join("\n");
}

let assetRoot = defaultAssetRoot;
let verifySourceBundle = true;
for (let index = 2; index < process.argv.length; index += 1) {
  const argument = process.argv[index];
  if (argument === "--asset-root") {
    const value = process.argv[index + 1];
    if (!value) {
      console.error("--asset-root requires a path");
      process.exit(2);
    }
    assetRoot = resolve(value);
    index += 1;
  } else if (argument === "--skip-source-bundle") {
    verifySourceBundle = false;
  } else if (argument === "--help") {
    console.log(usage());
    process.exit(0);
  } else {
    console.error(`unknown argument: ${argument}`);
    console.error(usage());
    process.exit(2);
  }
}

const result = await verifyReleaseAssets({ assetRoot, verifySourceBundle });
const output = formatVerification(result);
if (result.failures.length > 0) {
  console.error(output);
  process.exit(1);
}
console.log(output);
