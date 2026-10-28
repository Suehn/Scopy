import { math } from "micromark-extension-math";

// Backslash math participates in the same tokenizer as code, links, HTML, and dollar math.
// Source lookahead admits a complete delimiter pair; token consumption stays with micromark
// so container prefixes, code ownership, and source positions keep their native meaning.
export function backslashMath(source) {
  // micromark removes exactly one initial BOM before assigning token offsets. Keep every
  // lookahead, line boundary, and label lookup in that coordinate space without changing input.
  if (source.charCodeAt(0) === 0xfeff) source = source.slice(1);
  if (!source.includes("\\")) return {};
  const mathText = math({ singleDollarTextMath: false }).text[36];
  const hasLinkLabels = /\](?:\(|\[)/.test(source);
  const lineEnds = [];
  let lastDisplayCloser = -1;
  for (const match of source.matchAll(/\\\](?=[^\S\r\n]*(?:\r\n|\r|\n|$))|\r\n|\r|\n/gu)) {
    if (match[0][0] === "\\") lastDisplayCloser = match.index;
    else lineEnds.push(match.index);
  }
  lineEnds.push(source.length);
  const text = {
    name: "scopyBackslashMathText",
    resolve: mathText.resolve,
    tokenize(effects, ok, nok) {
      const context = this;
      const start = context.now().offset;
      const opener = source[start + 1];
      const lineEnd = lineEnds[context.now().line - 1];
      if ((opener !== "(" && opener !== "[") || (hasLinkLabels && inLinkLabel(context, source, lineEnd))) return nok;
      const relativeClose = source.slice(start + 2, lineEnd).indexOf(opener === "(" ? "\\)" : "\\]");
      if (relativeClose < 0) return nok;
      const close = start + 2 + relativeClose;
      if (!source.slice(start + 2, close).trim()) return nok;
      let dataOpen = false;
      return begin;

      function begin(code) {
        effects.enter("mathText");
        effects.enter("mathTextSequence");
        return opening(code);
      }
      function opening(code) {
        if (context.now().offset < start + 2) {
          effects.consume(code);
          return opening;
        }
        effects.exit("mathTextSequence");
        return body(code);
      }
      function body(code) {
        // A table cell or another phrasing boundary can end before the raw physical line.
        if (code === null || isLineEnding(code)) return nok(code);
        if (context.now().offset === close) {
          if (dataOpen) effects.exit("mathTextData");
          effects.enter("mathTextSequence");
          return closing(code);
        }
        if (code === 32) {
          if (dataOpen) effects.exit("mathTextData");
          dataOpen = false;
          effects.enter("space");
          effects.consume(code);
          effects.exit("space");
        } else {
          if (!dataOpen) effects.enter("mathTextData");
          dataOpen = true;
          effects.consume(code);
        }
        return body;
      }
      function closing(code) {
        if (context.now().offset < close + 2) {
          effects.consume(code);
          return closing;
        }
        effects.exit("mathTextSequence");
        effects.exit("mathText");
        return ok(code);
      }
    }
  };

  const literal = {
    name: "scopyBackslashMathLiteral",
    tokenize(effects, ok, nok) {
      const context = this;
      const start = context.now().offset;
      if (!"()[]".includes(source[start + 1] || "\0") || (hasLinkLabels && inLinkLabel(context, source, lineEnds[context.now().line - 1]))) return nok;
      return begin;
      function begin(code) {
        effects.enter("data");
        return consume(code);
      }
      function consume(code) {
        if (context.now().offset < start + 2) {
          effects.consume(code);
          return consume;
        }
        effects.exit("data");
        return ok(code);
      }
    }
  };

  const flow = {
    name: "scopyBackslashMathFlow",
    concrete: true,
    tokenize(effects, ok, nok) {
      const context = this;
      const start = context.now().offset;
      if (source[start + 1] !== "[") return nok;
      const lineEnd = lineEnds[context.now().line - 1];
      const relativeClose = source.slice(start + 2, lineEnd).indexOf("\\]");
      const singleLine = relativeClose >= 0;
      const firstClose = start + 2 + relativeClose;
      if (singleLine) {
        if (!source.slice(start + 2, firstClose).trim() || source.slice(firstClose + 2, lineEnd).trim()) return nok;
      } else if (source.slice(start + 2, lineEnd).trim() || lastDisplayCloser <= lineEnd) {
        return nok;
      }
      let hasContent = singleLine;
      return begin;

      function begin(code) {
        effects.enter("mathFlow");
        effects.enter("mathFlowFence");
        effects.enter("mathFlowFenceSequence");
        return opening(code);
      }
      function opening(code) {
        if (context.now().offset < start + 2) {
          effects.consume(code);
          return opening;
        }
        effects.exit("mathFlowFenceSequence");
        if (singleLine) {
          effects.exit("mathFlowFence");
          effects.enter("mathFlowValue");
          return singleBody(code);
        }
        return openingTail(code);
      }
      function openingTail(code) {
        if (isLineEnding(code)) {
          effects.exit("mathFlowFence");
          return lineEnding(code);
        }
        if (code === null) return nok(code);
        effects.consume(code);
        return openingTail;
      }
      function singleBody(code) {
        if (code === null || isLineEnding(code)) return nok(code);
        if (context.now().offset === firstClose) {
          effects.exit("mathFlowValue");
          effects.enter("mathFlowFence");
          effects.enter("mathFlowFenceSequence");
          return singleClosing(code);
        }
        effects.consume(code);
        return singleBody;
      }
      function singleClosing(code) {
        if (context.now().offset < firstClose + 2) {
          effects.consume(code);
          return singleClosing;
        }
        effects.exit("mathFlowFenceSequence");
        return closingTail(code);
      }
      function lineEnding(code) {
        effects.enter("lineEnding");
        effects.consume(code);
        effects.exit("lineEnding");
        return lineStart;
      }
      function lineStart(code) {
        if (code === null || context.parser.lazy[context.now().line]) return nok(code);
        return effects.attempt({ tokenize: closingLine, partial: true }, finish, contentStart)(code);
      }
      function contentStart(code) {
        if (isLineEnding(code)) return lineEnding(code);
        effects.enter("mathFlowValue");
        return content(code);
      }
      function content(code) {
        if (code === null) return nok(code);
        if (isLineEnding(code)) {
          effects.exit("mathFlowValue");
          return lineEnding(code);
        }
        if (!isBlank(code)) hasContent = true;
        effects.consume(code);
        return content;
      }
      function closingLine(effects, ok, nok) {
        return prefix;
        function prefix(code) {
          effects.enter("mathFlowFence");
          return whitespace(code);
        }
        function whitespace(code) {
          if (isBlank(code)) {
            effects.consume(code);
            return whitespace;
          }
          if (code !== 92) return nok(code);
          effects.enter("mathFlowFenceSequence");
          effects.consume(code);
          return bracket;
        }
        function bracket(code) {
          if (code !== 93) return nok(code);
          effects.consume(code);
          effects.exit("mathFlowFenceSequence");
          return tail;
        }
        function tail(code) {
          if (code === null || isLineEnding(code)) {
            effects.exit("mathFlowFence");
            return ok(code);
          }
          if (!isBlank(code)) return nok(code);
          effects.consume(code);
          return tail;
        }
      }
      function closingTail(code) {
        if (code === null || isLineEnding(code)) {
          effects.exit("mathFlowFence");
          return finish(code);
        }
        effects.consume(code);
        return closingTail;
      }
      function finish(code) {
        if (!hasContent) return nok(code);
        effects.exit("mathFlow");
        return ok(code);
      }
    }
  };

  return { text: { 92: [text, literal] }, flow: { 92: flow } };
}

function isLineEnding(code) {
  return code === -5 || code === -4 || code === -3;
}

function isBlank(code) {
  return code === -2 || code === -1 || (code > 0 && /\s/u.test(String.fromCharCode(code)));
}

// The existing backslash policy leaves a complete source link/image label to ordinary
// Markdown. Look only at label openers that the parser actually admitted on this line.
function inLinkLabel(context, source, lineEnd) {
  const here = context.now();
  for (let i = context.events.length - 1; i >= 0; i -= 1) {
    const [kind, token] = context.events[i];
    if (token.end && token.end.line < here.line) break;
    if (kind !== "enter" || (token.type !== "labelLink" && token.type !== "labelImage") || token._balanced) continue;
    const labelStart = token.start.offset + (token.type === "labelImage" ? 1 : 0);
    const labelEnd = matchingClose(source, labelStart, "[", "]", lineEnd);
    if (labelEnd < 0) continue;
    const open = source[labelEnd + 1];
    if ((open === "(" || open === "[") && matchingClose(source, labelEnd + 1, open, open === "(" ? ")" : "]", lineEnd) >= here.offset) return true;
  }
  return false;
}

function matchingClose(source, start, open, close, end) {
  let depth = 0;
  for (let i = start; i < end; i += 1) {
    if (source[i] === "\\") i += 1;
    else if (source[i] === open) depth += 1;
    else if (source[i] === close && --depth === 0) return i;
  }
  return -1;
}
