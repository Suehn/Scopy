import rehypeKatex from "rehype-katex";
import rehypeSanitize from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { preprocessBackslashMath } from "./scopyBackslashMathPreprocessor.js";

export function render(source, policy = {}) {
  const warnings = [];
  const normalizedPolicy = normalizePolicy(policy);

  if (normalizedPolicy.allowRawHTML) {
    warnings.push("raw HTML is not enabled in the first unified renderer bundle");
  }
  if (normalizedPolicy.allowLooseMathRepair) {
    warnings.push("loose math repair is not enabled in the first unified renderer bundle");
  }
  const originalSource = String(source || "");
  const preprocessed = normalizedPolicy.allowBackslashMath
    ? preprocessBackslashMath(originalSource)
    : { markdown: originalSource, mathCount: 0 };
  const processor = unified()
    .use(remarkParse)
    .use(remarkGfm)
    .use(remarkBreaks)
    .use(remarkMath);
  processor
    .use(remarkRehype, { allowDangerousHtml: false })
    .use(rehypeSanitize)
    .use(rehypeKatex, { throwOnError: false, strict: "ignore" })
    .use(rehypeStringify);

  const file = processor.processSync(preprocessed.markdown);
  return {
    html: String(file),
    metadata: {
      renderer: "unified",
      mathCount: countDollarMath(originalSource) + preprocessed.mathCount,
      repairedMathCount: 0,
      warnings
    }
  };
}

function normalizePolicy(policy) {
  return {
    profile: String(policy.profile || "plainTextUnknown"),
    allowExplicitMath: policy.allowExplicitMath !== false,
    allowBackslashMath: policy.allowBackslashMath !== false,
    allowLooseMathRepair: policy.allowLooseMathRepair === true,
    allowSafeHTMLSubset: policy.allowSafeHTMLSubset !== false,
    allowRawHTML: policy.allowRawHTML === true,
    policyVersion: String(policy.policyVersion || "")
  };
}

function countDollarMath(source) {
  let count = 0;
  for (let i = 0; i < source.length; i += 1) {
    if (source[i] === "$") {
      if (i > 0 && source[i - 1] === "\\") {
        continue;
      }
      count += 1;
      if (source[i + 1] === "$") {
        i += 1;
      }
    }
  }
  return Math.floor(count / 2);
}
