import Foundation

enum LaTeXInlineTextNormalizer {
    /// Normalizes a small subset of LaTeX inline formatting commands into Markdown.
    ///
    /// This runs *after* math protection, so it must never touch protected math placeholders.
    static func normalize(_ text: String) -> String {
        if text.isEmpty { return text }

        var outputLines: [String] = []
        outputLines.reserveCapacity(text.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFencedCodeBlock = false
        var fenceMarker: Character? = nil
        var fenceCount = 0

        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(lineSub)

            if let (marker, count) = MarkdownCodeSkipper.fencePrefix(in: line) {
                if !inFencedCodeBlock {
                    inFencedCodeBlock = true
                    fenceMarker = marker
                    fenceCount = count
                    outputLines.append(line)
                    continue
                }
                if marker == fenceMarker, count >= fenceCount {
                    inFencedCodeBlock = false
                    fenceMarker = nil
                    fenceCount = 0
                    outputLines.append(line)
                    continue
                }
            }

            if inFencedCodeBlock {
                outputLines.append(line)
                continue
            }

            line = MarkdownCodeSkipper.processInlineCode(in: line) { segment in
                normalizePlainTextSegment(segment)
            }
            outputLines.append(line)
        }

        return outputLines.joined(separator: "\n")
    }

    private static func normalizePlainTextSegment(_ text: String) -> String {
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
