import { render } from "./render.js";
import { freezeRichForExport, hydrateRich } from "./richInteractionRuntime.js";

const api = { freezeRichForExport, hydrateRich, render };

if (typeof window !== "undefined") {
  window.ScopyUnifiedMarkdown = api;
}

export { freezeRichForExport, hydrateRich, render };
