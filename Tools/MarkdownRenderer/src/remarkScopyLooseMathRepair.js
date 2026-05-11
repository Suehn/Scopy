const knownCommands = new Set([
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega",
  "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
  "mathcal", "mathbb", "mathrm", "mathbf", "mathit", "mathsf", "mathtt",
  "mathscr", "mathfrak", "operatorname",
  "text", "frac", "dfrac", "tfrac", "sqrt",
  "ln", "log", "exp",
  "sin", "cos", "tan", "cot", "sec", "csc",
  "arcsin", "arccos", "arctan",
  "sinh", "cosh", "tanh", "coth",
  "sum", "prod", "int", "iint", "iiint",
  "lim", "limsup", "liminf",
  "inf", "sup", "min", "max",
  "in", "notin", "mid", "cup", "cap", "setminus", "subset", "subseteq", "supset", "supseteq",
  "times", "cdot", "cdots", "ldots",
  "le", "leq", "leqslant", "ge", "geq", "geqslant", "neq", "approx", "sim",
  "to", "mapsto", "leftarrow", "rightarrow", "leftrightarrow", "Leftarrow", "Rightarrow", "Leftrightarrow",
  "land", "lor", "neg", "forall", "exists",
  "infty"
]);

const protectedAncestorTypes = new Set([
  "link",
  "image",
  "definition",
  "code",
  "inlineCode",
  "html",
  "footnoteDefinition",
  "footnoteReference",
  "table",
  "tableRow",
  "tableCell"
]);

export function remarkScopyLooseMathRepair(options = {}) {
  const policy = options.policy || {};
  const metadata = options.metadata || {};

  return function transformer(tree) {
    if (policy.allowLooseMathRepair !== true) {
      return;
    }
    metadata.repairedMathCount = metadata.repairedMathCount || 0;
    transformChildren(tree, []);
  };

  function transformChildren(parent, ancestors) {
    if (!Array.isArray(parent.children)) {
      return;
    }

    for (let index = 0; index < parent.children.length; index += 1) {
      const child = parent.children[index];
      const childAncestors = ancestors.concat(parent);
      if (child.type === "text" && !hasProtectedAncestor(childAncestors)) {
        const repaired = repairLooseMathText(child.value || "", policy);
        if (repaired.count > 0) {
          parent.children.splice(index, 1, ...repaired.nodes);
          metadata.repairedMathCount += repaired.count;
          index += repaired.nodes.length - 1;
        }
        continue;
      }
      transformChildren(child, childAncestors);
    }
  }
}

function hasProtectedAncestor(ancestors) {
  return ancestors.some((node) => protectedAncestorTypes.has(node.type));
}

function repairLooseMathText(value, policy) {
  const text = String(value || "");
  if (!text || text.length > 20000) {
    return { nodes: [{ type: "text", value: text }], count: 0 };
  }

  const nodes = [];
  let count = 0;
  let cursor = 0;
  let i = 0;

  while (i < text.length) {
    const candidate = findCandidate(text, i);
    if (!candidate) {
      i += 1;
      continue;
    }

    if (shouldWrapAsLooseMath(candidate.value, policy)) {
      appendText(nodes, text.slice(cursor, candidate.start));
      nodes.push(inlineMathNode(candidate.value));
      count += 1;
      cursor = candidate.end;
      i = candidate.end;
      continue;
    }

    i = Math.max(i + 1, candidate.start + 1);
  }

  if (count === 0) {
    return { nodes: [{ type: "text", value: text }], count: 0 };
  }

  appendText(nodes, text.slice(cursor));
  return { nodes, count };
}

function inlineMathNode(value) {
  return {
    type: "inlineMath",
    value,
    data: {
      hName: "code",
      hProperties: {
        className: ["language-math", "math-inline"]
      },
      hChildren: [{ type: "text", value }]
    }
  };
}

function findCandidate(text, start) {
  const ch = text[start];
  if (ch === "(") {
    const end = findBalancedEnd(text, start, "(", ")", 400);
    return end === -1 ? null : { start, end, value: text.slice(start, end) };
  }
  if (ch === "[") {
    const end = findBalancedEnd(text, start, "[", "]", 400);
    return end === -1 ? null : { start, end, value: text.slice(start, end) };
  }
  if (ch === "\\") {
    const end = findCommandExpressionEnd(text, start);
    return end === -1 ? null : { start, end, value: text.slice(start, end) };
  }
  return null;
}

function appendText(nodes, value) {
  if (!value) {
    return;
  }
  const last = nodes[nodes.length - 1];
  if (last && last.type === "text") {
    last.value += value;
  } else {
    nodes.push({ type: "text", value });
  }
}

function shouldWrapAsLooseMath(raw, policy) {
  const s = String(raw || "").trim();
  if (!s || s.length > 400) {
    return false;
  }
  if (s.includes("$") || s.includes("\\(") || s.includes("\\[")) {
    return false;
  }
  if (isPathLikeOrURLLike(s) || isCurrencyLike(s) || isCJKHeavy(s)) {
    return false;
  }
  if (containsKnownCommand(s)) {
    return true;
  }
  if (!/[\\_^]/.test(s)) {
    return false;
  }

  const inner = stripBalancedWrapper(s);
  if (isIdentifierLikeNonMath(inner)) {
    return false;
  }
  if (/^[A-Za-z](?:[_^](?:[A-Za-z0-9]|\{[^}]+\}))+$/.test(inner)) {
    return true;
  }
  return /[=+\-*/<>≤≥∑∫√{}]/.test(inner) && /[_^]/.test(inner);
}

function findBalancedEnd(text, start, open, close, maxLength) {
  let depth = 0;
  for (let i = start; i < text.length && i - start <= maxLength; i += 1) {
    if (text[i] === "\\") {
      i += 1;
      continue;
    }
    if (text[i] === open) {
      depth += 1;
    } else if (text[i] === close) {
      depth -= 1;
      if (depth === 0) {
        return i + 1;
      }
    }
  }
  return -1;
}

function findCommandExpressionEnd(text, start) {
  const command = commandNameAt(text, start);
  if (!command || !knownCommands.has(command.name)) {
    return -1;
  }

  let i = command.end;
  let consumedSuffix = false;
  while (i < text.length) {
    if (text[i] === "{") {
      const groupEnd = findBalancedEnd(text, i, "{", "}", 400);
      if (groupEnd === -1) {
        break;
      }
      i = groupEnd;
      consumedSuffix = true;
      continue;
    }
    if ((text[i] === "_" || text[i] === "^") && i + 1 < text.length) {
      const suffixEnd = consumeScriptSuffix(text, i + 1);
      if (suffixEnd === -1) {
        break;
      }
      i = suffixEnd;
      consumedSuffix = true;
      continue;
    }
    break;
  }

  return consumedSuffix || command.name.length <= 8 ? i : command.end;
}

function consumeScriptSuffix(text, start) {
  if (text[start] === "{") {
    return findBalancedEnd(text, start, "{", "}", 120);
  }
  if (/[A-Za-z0-9]/.test(text[start])) {
    return start + 1;
  }
  return -1;
}

function commandNameAt(text, start) {
  if (text[start] !== "\\") {
    return null;
  }
  let i = start + 1;
  let name = "";
  while (i < text.length && /[A-Za-z]/.test(text[i]) && name.length < 32) {
    name += text[i];
    i += 1;
  }
  return name ? { name, end: i } : null;
}

function containsKnownCommand(s) {
  for (let i = 0; i < s.length; i += 1) {
    if (s[i] !== "\\") {
      continue;
    }
    const command = commandNameAt(s, i);
    if (command && knownCommands.has(command.name)) {
      return true;
    }
  }
  return false;
}

function stripBalancedWrapper(s) {
  const trimmed = s.trim();
  if ((trimmed.startsWith("(") && trimmed.endsWith(")")) || (trimmed.startsWith("[") && trimmed.endsWith("]"))) {
    return trimmed.slice(1, -1).trim();
  }
  return trimmed;
}

function isIdentifierLikeNonMath(s) {
  return /^[A-Za-z][A-Za-z0-9-]{2,}[_^][A-Za-z0-9_-]+$/.test(s);
}

function isPathLikeOrURLLike(raw) {
  const trimmed = String(raw || "").trim();
  const lower = trimmed.toLowerCase();
  if (lower.includes("http://") || lower.includes("https://")) {
    return true;
  }
  if (lower.includes("file://") || lower.includes("mailto:") || lower.includes("://")) {
    return true;
  }
  if (trimmed.startsWith("~/") || trimmed.startsWith("./") || trimmed.startsWith("../")) {
    return true;
  }
  if (trimmed.includes("/Users/") || trimmed.includes("/Volumes/")) {
    return true;
  }
  if (/\.(md|markdown|tex|png|jpe?g|gif|webp|pdf)(:|\b)/i.test(trimmed)) {
    return true;
  }
  if (trimmed.includes("?") && trimmed.includes("=")) {
    return true;
  }
  const slashCount = [...trimmed].filter((ch) => ch === "/").length;
  return slashCount >= 2;
}

function isCurrencyLike(raw) {
  return /(^|[\s([{])[$€£¥]\s*\d/.test(String(raw || ""));
}

function isCJKHeavy(raw) {
  const s = String(raw || "").replace(/\s/g, "");
  if (s.length < 4) {
    return false;
  }
  let cjk = 0;
  for (const ch of s) {
    if (/[\u3400-\u9fff\uf900-\ufaff]/u.test(ch)) {
      cjk += 1;
    }
  }
  return cjk / s.length > 0.3;
}
