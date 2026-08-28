import { fromHtmlIsomorphic } from "hast-util-from-html-isomorphic";
import { toText } from "hast-util-to-text";
import katex from "katex";
import "katex/contrib/mhchem";
import { SKIP, visitParents } from "unist-util-visit-parents";

const emptyClasses = [];
const maximumUserSpecifiedSizeEm = 20;
export function rehypeScopyKatex(options = {}) {
  const failureMode = options.failureMode === "literal" ? "literal" : "relaxed";

  return function transformer(tree, file) {
    let renderedCount = 0;
    visitParents(tree, "element", (element, parents) => {
      const classes = Array.isArray(element.properties?.className)
        ? element.properties.className
        : emptyClasses;
      const languageMath = classes.includes("language-math");
      const mathDisplay = classes.includes("math-display");
      const mathInline = classes.includes("math-inline");
      if (!languageMath && !mathDisplay && !mathInline) {
        return;
      }

      let displayMode = mathDisplay;
      let scope = element;
      let parent = parents[parents.length - 1];
      if (
        element.tagName === "code" &&
        languageMath &&
        parent?.type === "element" &&
        parent.tagName === "pre"
      ) {
        scope = parent;
        parent = parents[parents.length - 2];
        displayMode = true;
      }
      if (!parent || !Array.isArray(parent.children)) {
        return;
      }

      const source = toText(scope, { whitespace: "pre" }).replace(/\n$/, "");
      const rendered = renderMath(source, displayMode, failureMode, file, parents, element);
      const host = {
        type: "element",
        tagName: "span",
        properties: {
          role: "math",
          ariaLabel: source,
          dataMathSource: source,
          dataClientKatexLayout: ""
        },
        children: rendered
      };
      const index = parent.children.indexOf(scope);
      if (index === -1) {
        return;
      }
      parent.children.splice(index, 1, host);
      renderedCount += 1;
      return SKIP;
    });
    file.data.scopyMathCount = renderedCount;
  };
}

function renderMath(source, displayMode, failureMode, file, parents, element) {
  try {
    return parseRenderedHTML(
      katex.renderToString(source, {
        displayMode,
        output: "html",
        strict: "error",
        throwOnError: true,
        trust: false,
        maxSize: maximumUserSpecifiedSizeEm
      })
    );
  } catch (error) {
    file.message("Could not render math with KaTeX", {
      ancestors: [...parents, element],
      cause: error,
      place: element.position,
      ruleId: String(error?.name || "katex").toLowerCase(),
      source: "scopy-katex"
    });
    if (failureMode === "relaxed") {
      try {
        return parseRenderedHTML(
          katex.renderToString(source, {
            displayMode,
            output: "html",
            strict: "ignore",
            throwOnError: false,
            trust: false,
            maxSize: maximumUserSpecifiedSizeEm
          })
        );
      } catch {
        // Fall through to the stable literal error surface.
      }
    }
    return [
      {
        type: "element",
        tagName: "span",
        properties: {
          className: ["katex-error"],
          title: String(error)
        },
        children: [{ type: "text", value: source }]
      }
    ];
  }
}

function parseRenderedHTML(html) {
  return fromHtmlIsomorphic(html, { fragment: true }).children;
}
