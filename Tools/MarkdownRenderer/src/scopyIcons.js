import assets from "./codexControlIconAssets.json" with { type: "json" };

// Original Codex artwork; the currency selector retains its existing Phosphor
// control because no equivalent combined icon was found in the installed app.
const currencyChevronPath = 'M181.66,170.34a8,8,0,0,1,0,11.32l-48,48a8,8,0,0,1-11.32,0l-48-48a8,8,0,0,1,11.32-11.32L128,212.69l42.34-42.35A8,8,0,0,1,181.66,170.34Zm-96-84.68L128,43.31l42.34,42.35a8,8,0,0,0,11.32-11.32l-48-48a8,8,0,0,0-11.32,0l-48,48A8,8,0,0,0,85.66,85.66Z';
export const SCOPY_ICON_NAMES = Object.freeze([...Object.keys(assets.icons), "caret-up-down"]);

export function scopyIcon(name) {
  if (name === "caret-up-down") return {
    type: "element", tagName: "svg",
    properties: { className: ["scopy-icon", "scopy-icon--caret-up-down"], viewBox: "0 0 256 256", width: 16, height: 16, ariaHidden: "true", focusable: "false" },
    children: [{ type: "element", tagName: "path", properties: { d: currencyChevronPath, fill: "currentColor" }, children: [] }]
  };
  if (!Object.hasOwn(assets.icons, name)) throw new Error(`Unknown Scopy icon: ${name}`);
  const icon = JSON.parse(JSON.stringify(assets.icons[name]));
  icon.properties = { className: ["scopy-icon", `scopy-icon--${name}`], ...icon.properties, ariaHidden: "true", focusable: "false" };
  return icon;
}
