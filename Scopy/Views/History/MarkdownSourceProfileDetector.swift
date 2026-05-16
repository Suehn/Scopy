import Foundation

enum MarkdownSourceProfileDetector {
    static func detect(_ text: String) -> MarkdownSourceProfile {
        let sample = String(text.prefix(80_000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .plainTextUnknown
        }

        if isLatexDocumentLike(sample) {
            return .latexDocumentLike
        }
        if isChatGPTMarkdown(sample) {
            return .chatGPTMarkdown
        }
        let markdownScore = markdownSignalScore(sample)
        if markdownScore >= 2 {
            return .authoredMarkdown
        }
        if isRichHTML(sample) {
            return .richHTML
        }
        if isScientificMarkdown(sample) {
            return .scientificMarkdown
        }
        if isPDFOCRScientific(sample) {
            return .pdfOCRScientific
        }
        return .plainTextUnknown
    }

    private static func isLatexDocumentLike(_ text: String) -> Bool {
        if text.contains("\\documentclass") || text.contains("\\begin{document}") {
            return true
        }

        let markers = [
            "\\section{",
            "\\subsection{",
            "\\begin{equation}",
            "\\begin{align}",
            "\\begin{tabular}",
            "\\begin{itemize}",
            "\\begin{enumerate}"
        ]
        return markers.reduce(0) { count, marker in
            count + (text.contains(marker) ? 1 : 0)
        } >= 2
    }

    private static func isChatGPTMarkdown(_ text: String) -> Bool {
        if text.contains("](/Users/") || text.contains("](/Volumes/") || text.contains("](file://") {
            return true
        }
        if text.contains("](~/") || text.contains("](./") || text.contains("](../") {
            return true
        }
        if text.contains("```") && text.contains("](") && text.contains("/docs/") {
            return true
        }
        return false
    }

    private static func isRichHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        let tags = [
            "<details", "<summary", "<kbd", "<mark", "<sub", "<sup",
            "<table", "<pre", "<code", "<blockquote", "<span", "<div"
        ]
        return tags.contains { lower.contains($0) }
    }

    private static func markdownSignalScore(_ text: String) -> Int {
        var score = 0
        if text.contains("```") { score += 1 }
        if text.hasPrefix("#") || text.contains("\n#") { score += 1 }
        if text.hasPrefix("- ") || text.contains("\n- ") || text.contains("\n* ") { score += 1 }
        if text.contains("\n1. ") { score += 1 }
        if text.contains("](") && text.contains("[") { score += 1 }
        if text.contains("| ---") || text.contains("|---") || text.contains("--- |") { score += 1 }
        if text.contains("**") || text.contains("__") || text.contains("`") { score += 1 }
        return score
    }

    private static func isScientificMarkdown(_ text: String) -> Bool {
        let hasMarkdown = markdownSignalScore(text) > 0
        guard hasMarkdown else { return false }
        if text.contains("$$") || text.contains("\\(") || text.contains("\\[") {
            return true
        }
        return latexCommandCount(in: text) >= 2
    }

    private static func isPDFOCRScientific(_ text: String) -> Bool {
        if text.contains("$$") || text.contains("\\(") || text.contains("\\[") {
            return false
        }
        if latexCommandCount(in: text) >= 3 {
            return true
        }

        let mathLikeLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let s = String(line)
                return s.count < 240 && (s.contains("_") || s.contains("^")) && (s.contains("=") || s.contains("{"))
            }
        return mathLikeLines.count >= 3
    }

    private static func latexCommandCount(in text: String) -> Int {
        let commands = [
            "\\mathcal", "\\mathbb", "\\frac", "\\sqrt", "\\sum", "\\prod",
            "\\int", "\\alpha", "\\beta", "\\gamma", "\\rho", "\\theta"
        ]
        return commands.reduce(0) { count, command in
            count + occurrences(of: command, in: text)
        }
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
