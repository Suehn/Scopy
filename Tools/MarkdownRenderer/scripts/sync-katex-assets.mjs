import {
  defaultAssetRoot,
  formatVerification,
  synchronizeReleaseAssets,
  verifyReleaseAssets
} from "./asset-contract.mjs";

const { manifest, removedFonts } = await synchronizeReleaseAssets({
  assetRoot: defaultAssetRoot,
  writeRenderer: false
});
const result = await verifyReleaseAssets({
  assetRoot: defaultAssetRoot,
  verifySourceBundle: false
});
if (result.failures.length > 0) {
  console.error(formatVerification(result));
  process.exit(1);
}

console.log(`synchronized katex ${manifest.katex.version} CSS and fonts`);
console.log(`recorded renderer sha256 ${manifest.renderer.sha256}`);
if (removedFonts.length > 0) {
  console.log(`removed obsolete fonts: ${removedFonts.join(", ")}`);
}
console.log(formatVerification(result));
