import remarkMath from "remark-math";
import { math } from "micromark-extension-math";
import { backslashMath } from "./scopyBackslashMath.js";

// Keep upstream dollar tokenization/AST handling, with single-dollar boundaries for currency,
// identifiers and paths. Backslash delimiters enter the same math nodes through native constructs.
export function remarkScopyMath(options = {}) {
  remarkMath.call(this, { singleDollarTextMath: false });
  const upstream = math({ singleDollarTextMath: true }).text[36];
  this.data().micromarkExtensions.push({
    text: {
      36: {
        ...upstream,
        tokenize(effects, ok, nok) {
          const context = this;
          const before = context.previous;
          if (before > 0 && /[\w/\\.$]/u.test(String.fromCodePoint(before))) {
            return nok;
          }
          return upstream.tokenize.call(context, effects, (after) => {
            const token = context.events[context.events.length - 1][1];
            const source = context.sliceSerialize(token);
            const body = source.slice(1, -1);
            if (source.startsWith("$$") || !body || /^\s|\s$/u.test(body)
                || /[\r\n]/u.test(body)
                || (after > 0 && /[\w/\\$]/u.test(String.fromCodePoint(after)))) {
              return nok(after);
            }
            return ok(after);
          }, nok);
        }
      }
    }
  });
  this.data().micromarkExtensions.push(backslashMath(options.source || ""));
}
