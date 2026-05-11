import { render } from "./render.js";

const api = { render };

if (typeof window !== "undefined") {
  window.ScopyUnifiedMarkdown = api;
}

export { render };
