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

        // Heuristic: at least two '$' with content between them.
        // Avoid scanning huge strings too deeply; math detection is best-effort.
        var dollarCount = 0
        var scanned = 0
        for ch in text {
            if ch == "$" {
                dollarCount += 1
                if dollarCount >= 2 { return true }
            }
            scanned += 1
            if scanned >= 200_000 { break }
        }
        return false
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
}
