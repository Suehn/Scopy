import Foundation

enum LaTeXDocumentNormalizer {
    static func normalize(_ text: String) -> String {
        if text.isEmpty { return text }

        var outputLines: [String] = []
        outputLines.reserveCapacity(text.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFencedCodeBlock = false
        var fenceMarker: Character? = nil
        var fenceCount = 0

        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)

            if let (marker, count) = fencePrefix(in: line) {
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

            if let converted = convertHeadingLine(line) {
                outputLines.append(converted)
            } else {
                outputLines.append(line)
            }
        }

        return outputLines.joined(separator: "\n")
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

    private static func fencePrefix(in line: String) -> (Character, Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        return count >= 3 ? (first, count) : nil
    }
}

