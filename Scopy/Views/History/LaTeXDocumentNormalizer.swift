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

        var inTabularBlock = false
        var tabularLines: [String] = []
        tabularLines.reserveCapacity(32)

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

            if inTabularBlock {
                if isEndEnvironmentLine(line, name: "tabular") {
                    inTabularBlock = false
                    let tableLines = convertTabularToMarkdownTable(tabularLines)
                    tabularLines.removeAll(keepingCapacity: true)
                    for t in tableLines {
                        outputLines.append(applyQuotePrefixIfNeeded(t, inQuoteBlock: inQuoteBlock))
                    }
                    continue
                }
                tabularLines.append(line)
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
            if isBeginEnvironmentLine(line, name: "center") {
                continue
            }
            if isEndEnvironmentLine(line, name: "center") {
                continue
            }
            if isBeginTabularEnvironmentLine(line) {
                inTabularBlock = true
                tabularLines.removeAll(keepingCapacity: true)
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

            if let converted = convertHorizontalRuleLine(line) {
                outputLines.append(applyQuotePrefixIfNeeded(converted, inQuoteBlock: inQuoteBlock))
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

    private static func isBeginTabularEnvironmentLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("\\begin{tabular}")
            || t.hasPrefix("\\begin{tabular}{")
            || t.hasPrefix("\\begin{tabular*}")
            || t.hasPrefix("\\begin{tabular*}{")
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

    private static func convertHorizontalRuleLine(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains("\\rule{\\linewidth}") || t.contains("\\rule{\\textwidth}") else { return nil }
        if t.hasPrefix("\\noindent\\rule{\\linewidth}") || t.hasPrefix("\\rule{\\linewidth}") {
            return "---"
        }
        if t.hasPrefix("\\noindent\\rule{\\textwidth}") || t.hasPrefix("\\rule{\\textwidth}") {
            return "---"
        }
        return nil
    }

    private static func convertTabularToMarkdownTable(_ lines: [String]) -> [String] {
        // Best-effort conversion of:
        // \begin{tabular}{|l|l|}
        // \hline
        // A & B \\
        // \hline
        // ... \\
        // \hline
        // \end{tabular}
        //
        // into a Markdown pipe table.
        var rawRows: [String] = []
        rawRows.reserveCapacity(16)

        var current = ""

        func flushRow(_ row: String) {
            let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            rawRows.append(trimmed)
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t == "\\hline" || t == "\\hline{}" || t.hasPrefix("\\hline%") { continue }

            current += current.isEmpty ? t : " " + t

            while let range = current.range(of: "\\\\") {
                let before = String(current[..<range.lowerBound])
                flushRow(before)
                current = String(current[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        flushRow(current)

        guard !rawRows.isEmpty else { return [] }
        let headerCells = splitTabularCells(rawRows[0])
        guard !headerCells.isEmpty else { return lines }
        let columnCount = headerCells.count

        var out: [String] = []
        out.reserveCapacity(rawRows.count + 2)

        out.append("| " + headerCells.joined(separator: " | ") + " |")
        out.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")

        if rawRows.count > 1 {
            for row in rawRows.dropFirst() {
                var cells = splitTabularCells(row)
                if cells.count < columnCount {
                    cells.append(contentsOf: Array(repeating: "", count: columnCount - cells.count))
                } else if cells.count > columnCount {
                    let head = cells.prefix(columnCount - 1)
                    let tail = cells.suffix(cells.count - (columnCount - 1)).joined(separator: " ")
                    cells = Array(head) + [tail]
                }
                out.append("| " + cells.joined(separator: " | ") + " |")
            }
        }

        return out
    }

    private static func splitTabularCells(_ row: String) -> [String] {
        var cells: [String] = []
        cells.reserveCapacity(4)

        var current = ""
        current.reserveCapacity(row.count)

        var prevWasBackslash = false
        for ch in row {
            if ch == "&", !prevWasBackslash {
                cells.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                prevWasBackslash = false
                continue
            }
            current.append(ch)
            prevWasBackslash = ch == "\\"
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty || !cells.isEmpty {
            cells.append(last)
        }
        return cells
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
