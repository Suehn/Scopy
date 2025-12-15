import Foundation

enum LaTeXInlineTextNormalizer {
    /// Normalizes a small subset of LaTeX inline formatting commands into Markdown.
    ///
    /// This runs *after* math protection, so it must never touch protected math placeholders.
    static func normalize(_ text: String) -> String {
        if text.isEmpty { return text }

        var out = text
        out = replaceCommandWithBracedArg(out, command: "\\textbf", wrap: { "**\($0)**" })
        out = replaceCommandWithBracedArg(out, command: "\\emph", wrap: { "*\($0)*" })
        out = replaceCommandWithBracedArg(out, command: "\\textit", wrap: { "*\($0)*" })
        return out
    }

    private static func replaceCommandWithBracedArg(_ text: String, command: String, wrap: (String) -> String) -> String {
        guard text.contains(command + "{") else { return text }

        var out = ""
        out.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            guard let range = text.range(of: command + "{", range: i..<text.endIndex) else {
                out += text[i..<text.endIndex]
                break
            }
            out += text[i..<range.lowerBound]

            let argStart = range.upperBound
            var j = argStart
            var depth = 1
            var scanned = 0
            while j < text.endIndex, scanned < 10_000 {
                let ch = text[j]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                j = text.index(after: j)
                scanned += 1
            }

            guard j < text.endIndex, depth == 0 else {
                // Unbalanced; keep original.
                out += text[range.lowerBound..<text.endIndex]
                break
            }

            let inner = String(text[argStart..<j])
            out += wrap(inner)
            i = text.index(after: j)
        }

        return out
    }
}

