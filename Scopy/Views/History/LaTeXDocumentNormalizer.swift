import Foundation

enum LaTeXDocumentNormalizer {
    static func normalize(_ text: String) -> String {
        if text.isEmpty { return text }

        let normalizedNewlines = normalizeNewlines(text)

        var outputLines: [String] = []
        outputLines.reserveCapacity(normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFencedCodeBlock = false
        var fenceMarker: Character? = nil
        var fenceCount = 0

        var listStack: [ListKind] = []
        var inQuoteBlock = false

        for lineSub in normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
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

            // Drop common document-only metadata commands.
            // Do not drop labels when the entire line is an inline code span like: `\label{...}`
            if isLabelOnlyLine(line), !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("`") {
                continue
            }
            line = MarkdownCodeSkipper.processInlineCode(in: line) { segment in
                removeInlineLabel(segment)
            }

            // Block environments -> Markdown.
            if isBeginEnvironmentLine(line, name: "quote") {
                inQuoteBlock = true
                continue
            }
            if isEndEnvironmentLine(line, name: "quote") {
                inQuoteBlock = false
                continue
            }
            if isBeginEnvironmentLine(line, name: "itemize") {
                listStack.append(.bullet)
                continue
            }
            if isEndEnvironmentLine(line, name: "itemize") {
                if listStack.last == .bullet { _ = listStack.popLast() }
                continue
            }
            if isBeginEnvironmentLine(line, name: "enumerate") {
                listStack.append(.ordered)
                continue
            }
            if isEndEnvironmentLine(line, name: "enumerate") {
                if listStack.last == .ordered { _ = listStack.popLast() }
                continue
            }

            if let converted = convertHeadingLine(line) {
                outputLines.append(applyQuotePrefixIfNeeded(converted, inQuoteBlock: inQuoteBlock))
                continue
            }
            if let converted = convertParagraphHeadingLine(line) {
                outputLines.append(applyQuotePrefixIfNeeded(converted, inQuoteBlock: inQuoteBlock))
                continue
            }

            if let itemLine = convertItemLine(line, listStack: listStack) {
                outputLines.append(applyQuotePrefixIfNeeded(itemLine, inQuoteBlock: inQuoteBlock))
                continue
            }

            outputLines.append(applyQuotePrefixIfNeeded(line, inQuoteBlock: inQuoteBlock))
        }

        return outputLines.joined(separator: "\n")
    }

    private enum ListKind: Equatable {
        case bullet
        case ordered
    }

    private static func convertHeadingLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\") else { return nil }

        let mappings: [(command: String, prefix: String)] = [
            ("section", "#"),
            ("subsection", "##"),
            ("subsubsection", "###")
        ]

        for mapping in mappings {
            for star in ["", "*"] {
                let head = "\\\(mapping.command)\(star){"
                guard trimmed.hasPrefix(head), trimmed.hasSuffix("}") else { continue }
                let inner = String(trimmed.dropFirst(head.count).dropLast())
                if inner.isEmpty { return nil }
                return "\(mapping.prefix) \(inner)"
            }
        }

        return nil
    }

    private static func convertParagraphHeadingLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\") else { return nil }

        let mappings: [(command: String, prefix: String)] = [
            ("paragraph", "####"),
            ("subparagraph", "#####")
        ]

        for mapping in mappings {
            for star in ["", "*"] {
                let head = "\\\(mapping.command)\(star){"
                guard trimmed.hasPrefix(head), trimmed.hasSuffix("}") else { continue }
                let inner = String(trimmed.dropFirst(head.count).dropLast())
                if inner.isEmpty { return nil }
                return "\(mapping.prefix) \(inner)"
            }
        }

        return nil
    }

    private static func convertItemLine(_ line: String, listStack: [ListKind]) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\item") else { return nil }

        let kind = listStack.last ?? .bullet
        let indentLevel = max(0, listStack.count - 1)
        let indent = String(repeating: "  ", count: indentLevel)

        var rest = String(trimmed.dropFirst("\\item".count))
        rest = stripOptionalBracketPrefix(rest)
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .bullet:
            return indent + "- " + rest
        case .ordered:
            // Markdown allows all items to be `1.`; renderer will auto-number.
            return indent + "1. " + rest
        }
    }

    private static func stripOptionalBracketPrefix(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return s }

        var depth = 0
        for (idx, ch) in trimmed.enumerated() {
            if ch == "[" { depth += 1 }
            if ch == "]" {
                depth -= 1
                if depth == 0 {
                    let after = trimmed.index(trimmed.startIndex, offsetBy: idx + 1)
                    return String(trimmed[after...])
                }
            }
        }
        return s
    }

    private static func isBeginEnvironmentLine(_ line: String, name: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = "\\begin{\(name)}"
        return t == head || t.hasPrefix(head + "[")
    }

    private static func isEndEnvironmentLine(_ line: String, name: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "\\end{\(name)}"
    }

    private static func isLabelOnlyLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("\\label{") && t.hasSuffix("}")
    }

    private static func removeInlineLabel(_ line: String) -> String {
        guard line.contains("\\label{") else { return line }
        var out = line
        while let range = out.range(of: "\\label{") {
            var i = range.upperBound
            var depth = 1
            var scanned = 0
            while i < out.endIndex, scanned < 4_000 {
                let ch = out[i]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        i = out.index(after: i)
                        break
                    }
                }
                i = out.index(after: i)
                scanned += 1
            }
            let end = i
            out.removeSubrange(range.lowerBound..<end)
        }
        return out
    }

    private static func applyQuotePrefixIfNeeded(_ line: String, inQuoteBlock: Bool) -> String {
        guard inQuoteBlock else { return line }
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return line }
        return "> " + line
    }

    private static func normalizeNewlines(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        out = out.replacingOccurrences(of: "\u{2028}", with: "\n")
        out = out.replacingOccurrences(of: "\u{2029}", with: "\n")
        return out
    }
}
