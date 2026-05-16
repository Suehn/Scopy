import rehypeHighlight from "rehype-highlight";
import rehypeKatex from "rehype-katex";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { preprocessBackslashMath } from "./scopyBackslashMathPreprocessor.js";
import { preprocessDollarMathGuards } from "./scopyDollarMathGuards.js";
import { remarkScopyLooseMathRepair } from "./remarkScopyLooseMathRepair.js";
import { applySafeHTMLReplacements, preprocessSafeHTML } from "./scopySafeHTMLPreprocessor.js";

export function render(source, policy = {}) {
  return renderInternal(source, policy, 0);
}

function renderInternal(source, policy = {}, depth = 0) {
  const warnings = [];
  const normalizedPolicy = normalizePolicy(policy);

  if (normalizedPolicy.allowRawHTML) {
    warnings.push("raw HTML is not enabled in the first unified renderer bundle");
  }
  const originalSource = String(source || "");
  const safeHTML = normalizedPolicy.allowSafeHTMLSubset
    ? preprocessSafeHTML(originalSource)
    : { markdown: originalSource, replacements: {} };
  const dollarGuarded = preprocessDollarMathGuards(safeHTML.markdown);
  const preprocessed = normalizedPolicy.allowBackslashMath
    ? preprocessBackslashMath(dollarGuarded)
    : { markdown: dollarGuarded, mathCount: 0 };
  const repairMetadata = { repairedMathCount: 0 };
  const processor = unified()
    .use(remarkParse)
    .use(remarkGfm)
    .use(remarkBreaks)
    .use(remarkMath)
    .use(remarkScopyLooseMathRepair, {
      policy: normalizedPolicy,
      metadata: repairMetadata
    });
  processor
    .use(remarkRehype, { allowDangerousHtml: false })
    .use(rehypeSanitize, scopySanitizeSchema)
    .use(rehypeHighlight, scopyHighlightOptions)
    .use(rehypeKatex, { throwOnError: false, strict: "ignore" })
    .use(rehypeStringify);

  const file = processor.processSync(preprocessed.markdown);
  const html = normalizedPolicy.allowSafeHTMLSubset
    ? applySafeHTMLReplacements(String(file), safeHTML.replacements, (nestedMarkdown) => {
        if (depth > 4) {
          return "";
        }
        return renderInternal(nestedMarkdown, normalizedPolicy, depth + 1).html;
      })
    : String(file);
  return {
    html,
    metadata: {
      renderer: "unified",
      mathCount: countDollarMath(dollarGuarded) + preprocessed.mathCount + repairMetadata.repairedMathCount,
      repairedMathCount: repairMetadata.repairedMathCount,
      warnings
    }
  };
}

const scopySanitizeSchema = {
  ...defaultSchema,
  protocols: {
    ...defaultSchema.protocols,
    href: [...(defaultSchema.protocols?.href || []), "plugin"]
  }
};

const scopyHighlightOptions = {
  detect: false,
  plainText: ["text", "txt", "plain", "plaintext"],
  aliases: {
    bash: ["sh", "shell", "zsh"],
    javascript: ["js", "jsx"],
    markdown: ["md"],
    objectivec: ["objc", "objective-c"],
    python: ["py"],
    typescript: ["ts", "tsx"],
    yaml: ["yml"]
  }
};

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
