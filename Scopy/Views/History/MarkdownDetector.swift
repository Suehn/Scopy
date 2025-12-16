import Foundation

enum MarkdownDetector {
    static func isLikelyMarkdown(_ text: String) -> Bool {
        if text.isEmpty { return false }
        // Hover preview never renders Markdown for extremely large payloads anyway; keep detection cheap.
        if text.utf16.count > 200_000 { return false }

        if containsMath(text) { return true }

        // LaTeX-ish documents (common from papers/notes) should still be rendered
        // via the Markdown preview pipeline for readability and math support.
        if text.contains("\\begin{") || text.contains("\\end{") { return true }
        if text.contains("\\section{") || text.contains("\\subsection{") || text.contains("\\subsubsection{") { return true }

        // Fast common signals (avoid regex).
        if text.contains("```") { return true }
        if text.contains("\n#") || text.hasPrefix("#") { return true }
        if text.contains("\n- ") || text.hasPrefix("- ") { return true }
        if text.contains("\n* ") || text.hasPrefix("* ") { return true }
        if text.contains("\n1. ") { return true }
        if text.contains("](") && text.contains("[") { return true }
        if text.contains("**") || text.contains("__") { return true }
        if text.contains("`") { return true }
        if text.contains("> ") || text.contains("\n> ") { return true }
        if text.contains("---") || text.contains("\n---\n") { return true }

        // Table heuristic: a header row + separator row.
        if text.contains("|") {
            if text.contains("\n|") && (text.contains("| ---") || text.contains("|---") || text.contains("--- |")) {
                return true
            }
        }

        return false
    }

    static func containsMath(_ text: String) -> Bool {
        if text.contains("$$") { return true }
        if text.contains("\\(") || text.contains("\\)") { return true }
        if text.contains("\\[") || text.contains("\\]") { return true }
        // Common environment-style display math.
        if text.contains("\\begin{equation}") || text.contains("\\begin{align}") || text.contains("\\begin{aligned}") { return true }
        if text.contains("\\begin{cases}") { return true }
        if containsKnownLaTeXCommand(text) { return true }

        // Detect paired `$...$` inline math. Do not treat mere multiple `$` (e.g. currency, shell vars)
        // as math; this avoids routing plain text through the Markdown+KaTeX pipeline.
        return containsPairedInlineDollarMath(text, maxScanUTF16: 200_000)
    }

    private static let latexCommands: Set<String> = [
        "mathcal", "mathbb", "mathrm", "mathbf", "mathit", "mathsf", "mathtt",
        "text", "frac", "dfrac", "tfrac", "sqrt",
        "sum", "prod", "int", "iint", "iiint",
        "in", "notin", "mid", "cup", "cap", "setminus", "subset", "subseteq", "supset", "supseteq",
        "times", "cdot", "cdots", "ldots",
        "le", "leq", "ge", "geq", "neq", "approx", "sim",
        "to", "mapsto", "leftarrow", "rightarrow", "leftrightarrow", "Leftarrow", "Rightarrow", "Leftrightarrow",
        "land", "lor", "neg", "forall", "exists",
        "begin", "end",
        "ce"
    ]

    static func containsKnownLaTeXCommand(_ text: String) -> Bool {
        guard text.contains("\\") else { return false }

        var i = text.startIndex
        var scanned = 0
        while i < text.endIndex, scanned < 200_000 {
            if text[i] != "\\" {
                i = text.index(after: i)
                scanned += 1
                continue
            }
            var j = text.index(after: i)
            var name = ""
            while j < text.endIndex, scanned < 200_000 {
                let c = text[j]
                if c.isLetter {
                    name.append(c)
                    if name.count >= 32 { break }
                    j = text.index(after: j)
                    scanned += 1
                    continue
                }
                break
            }
            if !name.isEmpty, latexCommands.contains(name) {
                return true
            }
            i = j
        }
        return false
    }

    private static func containsPairedInlineDollarMath(_ text: String, maxScanUTF16: Int) -> Bool {
        guard text.contains("$") else { return false }

        var i = text.startIndex
        var scanned = 0
        while i < text.endIndex, scanned < maxScanUTF16 {
            guard text[i] == "$" else {
                i = text.index(after: i)
                scanned += 1
                continue
            }

            // Ignore escaped dollars.
            if i > text.startIndex, text[text.index(before: i)] == "\\" {
                i = text.index(after: i)
                scanned += 1
                continue
            }

            let next = text.index(after: i)
            // Skip `$$` here; `contains("$$")` already handled above.
            if next < text.endIndex, text[next] == "$" {
                i = text.index(after: next)
                scanned += 2
                continue
            }

            let afterStart = next
            guard let end = findClosingInlineDollar(in: text, from: afterStart, maxScanUTF16: maxScanUTF16 - scanned) else {
                // Unclosed `$`: treat as plain text.
                i = text.index(after: i)
                scanned += 1
                continue
            }

            let inner = text[afterStart..<end]
            // Require some non-whitespace content to reduce false positives like `$ $`.
            if inner.contains(where: { !$0.isWhitespace && !$0.isNewline }) {
                return true
            }

            i = text.index(after: end)
            scanned += 2
        }

        return false
    }

    private static func findClosingInlineDollar(
        in text: String,
        from index: String.Index,
        maxScanUTF16: Int
    ) -> String.Index? {
        var i = index
        var scanned = 0
        while i < text.endIndex, scanned < maxScanUTF16 {
            if text[i] == "$" {
                // Ignore escaped dollars.
                if i > text.startIndex, text[text.index(before: i)] == "\\" {
                    i = text.index(after: i)
                    scanned += 1
                    continue
                }
                // Ignore `$$` here.
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "$" {
                    i = text.index(after: next)
                    scanned += 2
                    continue
                }
                // Heuristic: treat `$` as a closing delimiter only when it's followed by a boundary.
                // This avoids false positives for currency/variables like "$5 ... $6" / "$HOME ... $PATH",
                // where the next `$` is usually an opening delimiter (immediately followed by a word/digit).
                if isClosingDollarBoundary(text, at: i) {
                    return i
                }
            }
            i = text.index(after: i)
            scanned += 1
        }
        return nil
    }

    private static func isClosingDollarBoundary(_ text: String, at dollar: String.Index) -> Bool {
        let after = text.index(after: dollar)
        guard after < text.endIndex else { return true }
        let ch = text[after]
        if ch.isWhitespace || ch.isNewline { return true }
        if ch.isLetter || ch.isNumber { return false }
        if ch == "_" { return false }
        return true
    }
}
