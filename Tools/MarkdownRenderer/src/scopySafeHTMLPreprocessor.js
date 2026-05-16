export function preprocessSafeHTML(source) {
  const salt = makeSalt(source);
  const state = {
    salt,
    index: 0,
    replacements: {}
  };
  return preprocessSafeHTMLWithState(source, state);
}

function preprocessSafeHTMLWithState(source, state) {
  const protectedCode = protectFencedCodeBlocks(String(source || ""), state);
  let markdown = protectedCode.markdown.replace(/<!--[\s\S]*?-->/g, "");
  markdown = replaceDetails(markdown, state);
  markdown = replaceInlineTags(markdown, state);
  markdown = restoreProtectedCodeBlocks(markdown, protectedCode.placeholders);
  return { markdown, replacements: state.replacements };
}

export function applySafeHTMLReplacements(html, replacements, renderMarkdown) {
  let output = String(html || "");
  const keys = Object.keys(replacements || {}).sort((a, b) => b.length - a.length);
  for (const key of keys) {
    if (!output.includes(key)) {
      continue;
    }
    const paragraphPattern = new RegExp(`<p>\\s*${escapeRegExp(key)}\\s*<\\/p>`, "g");
    output = output.replace(paragraphPattern, () => renderSafeHTMLToken(replacements[key], renderMarkdown));
  }
  for (const key of keys) {
    if (!output.includes(key)) {
      continue;
    }
    const rendered = renderSafeHTMLToken(replacements[key], renderMarkdown);
    output = output.split(key).join(rendered);
  }
  return output;
}

function protectFencedCodeBlocks(source, state) {
  const lines = source.split("\n");
  const placeholders = {};
  const output = [];
  let active = null;

  for (const line of lines) {
    const fence = fenceMarker(line);
    if (fence) {
      if (active) {
        active.lines.push(line);
        if (fence.marker === active.marker && fence.length >= active.length) {
          placeholders[active.token] = active.lines.join("\n");
          output.push(active.token);
          active = null;
        }
      } else {
        active = {
          marker: fence.marker,
          length: fence.length,
          token: nextToken(state, "SCOPYSAFECODE"),
          lines: [line]
        };
      }
      continue;
    }

    if (active) {
      active.lines.push(line);
    } else {
      output.push(line);
    }
  }

  if (active) {
    placeholders[active.token] = active.lines.join("\n");
    output.push(active.token);
  }

  return { markdown: output.join("\n"), placeholders };
}

function restoreProtectedCodeBlocks(markdown, placeholders) {
  let restored = markdown;
  for (const [token, original] of Object.entries(placeholders)) {
    restored = restored.split(token).join(original);
  }
  return restored;
}

function replaceDetails(markdown, state) {
  return markdown.replace(/<details(\s+open)?\s*>([\s\S]*?)<\/details>/gi, (_whole, open, inner) => {
    const summaryMatch = /<summary\s*>([\s\S]*?)<\/summary>/i.exec(inner);
    let summary = "";
    let body = inner;
    if (summaryMatch) {
      summary = preprocessSafeHTMLWithState(summaryMatch[1], state).markdown.trim();
      body = inner.replace(summaryMatch[0], "");
    }
    body = preprocessSafeHTMLWithState(body, state).markdown.trim();
    const token = nextToken(state);
    state.replacements[token] = {
      kind: "details",
      isOpen: Boolean(open),
      summary,
      body
    };
    return `\n\n${token}\n\n`;
  });
}

function replaceInlineTags(markdown, state) {
  return markdown
    .split("\n")
    .map((line) => replaceInlineTagsOutsideCode(line, state))
    .join("\n");
}

function replaceInlineTagsOutsideCode(line, state) {
  let i = 0;
  let out = "";
  while (i < line.length) {
    if (line[i] === "`") {
      const end = findClosingBacktickRun(line, i);
      if (end !== -1) {
        out += line.slice(i, end);
        i = end;
        continue;
      }
    }

    const match = /^<(u|kbd|mark|sub|sup)>([\s\S]*?)<\/\1>/i.exec(line.slice(i));
    if (match) {
      const tag = match[1].toLowerCase();
      const token = nextToken(state);
      state.replacements[token] = {
        kind: "inlineTag",
        tag,
        text: match[2]
      };
      out += token;
      i += match[0].length;
      continue;
    }

    out += line[i];
    i += 1;
  }
  return out;
}

function renderSafeHTMLToken(item, renderMarkdown) {
  if (!item) {
    return "";
  }
  if (item.kind === "inlineTag") {
    const tag = item.tag || "span";
    return `<${tag}>${escapeHTML(item.text || "")}</${tag}>`;
  }
  if (item.kind === "details") {
    const summaryHTML = item.summary ? unwrapSingleParagraph(renderMarkdown(item.summary)) : "";
    const bodyHTML = item.body ? renderMarkdown(item.body) : "";
    return `<details class="scopy-details"${item.isOpen ? " open" : ""}><summary>${summaryHTML}</summary>${bodyHTML}</details>`;
  }
  return "";
}

function fenceMarker(line) {
  const match = /^( {0,3})(`{3,}|~{3,})/.exec(line);
  if (!match) {
    return null;
  }
  const run = match[2];
  return { marker: run[0], length: run.length };
}

function findClosingBacktickRun(line, start) {
  let runLength = 0;
  while (line[start + runLength] === "`") {
    runLength += 1;
  }
  const needle = "`".repeat(runLength);
  const close = line.indexOf(needle, start + runLength);
  return close === -1 ? -1 : close + runLength;
}

function nextToken(state, prefix = "SCOPYSAFEHTMLPLACEHOLDER") {
  const token = `${prefix}${state.salt}${state.index}X`;
  state.index += 1;
  return token;
}

function makeSalt(source) {
  const random = Math.random().toString(16).slice(2);
  if (!String(source || "").includes(random)) {
    return random;
  }
  return `${Date.now().toString(16)}${random}`;
}

function escapeHTML(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function unwrapSingleParagraph(html) {
  const match = /^<p>([\s\S]*?)<\/p>\s*$/.exec(String(html || ""));
  return match ? match[1] : html;
}

function escapeRegExp(text) {
  return String(text || "").replace(/[\\^$.*+?()[\]{}|]/g, "\\$&");
}
