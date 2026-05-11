import Foundation

struct MarkdownSyntaxProtectionResult {
    let markdown: String
    let placeholders: [(placeholder: String, original: String, kind: MarkdownSyntaxIslandKind)]
}

enum MarkdownSyntaxIslandKind: Equatable {
    case fencedCode
    case inlineCode
    case inlineLink
    case image
    case referenceLink
    case shortcutReference
    case referenceDefinition
    case autolink
    case safeHTML
    case url
    case filePath
}

enum MarkdownSyntaxProtector {
    static func protectForLooseMathRepair(_ markdown: String) -> MarkdownSyntaxProtectionResult {
        guard !markdown.isEmpty else {
            return MarkdownSyntaxProtectionResult(markdown: markdown, placeholders: [])
        }

        var protector = Protector(source: markdown)
        return protector.protect(markdown)
    }

    static func restore(
        _ markdown: String,
        placeholders: [(placeholder: String, original: String, kind: MarkdownSyntaxIslandKind)]
    ) -> String {
        guard !placeholders.isEmpty else { return markdown }
        var restored = markdown
        for item in placeholders.reversed() {
            restored = restored.replacingOccurrences(of: item.placeholder, with: item.original)
        }
        return restored
    }

    private struct Protector {
        private let placeholderPrefix: String
        private var placeholders: [(placeholder: String, original: String, kind: MarkdownSyntaxIslandKind)] = []

        init(source: String) {
            self.placeholderPrefix = Self.makePlaceholderPrefix(avoiding: source)
        }

        mutating func protect(_ source: String) -> MarkdownSyntaxProtectionResult {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var output: [String] = []
            output.reserveCapacity(lines.count)

            var activeFence: (marker: Character, count: Int, lines: [String])?

            for line in lines {
                if let fence = MarkdownCodeSkipper.fencePrefix(in: line) {
                    if var current = activeFence {
                        current.lines.append(line)
                        if current.marker == fence.0, fence.1 >= current.count {
                            output.append(protect(current.lines.joined(separator: "\n"), kind: .fencedCode))
                            activeFence = nil
                        } else {
                            activeFence = current
                        }
                        continue
                    }

                    activeFence = (marker: fence.0, count: fence.1, lines: [line])
                    continue
                }

                if var current = activeFence {
                    current.lines.append(line)
                    activeFence = current
                    continue
                }

                if isReferenceDefinitionLine(line) {
                    output.append(protect(line, kind: .referenceDefinition))
                    continue
                }

                output.append(protectInlineSyntax(in: line))
            }

            if let current = activeFence {
                output.append(protect(current.lines.joined(separator: "\n"), kind: .fencedCode))
            }

            return MarkdownSyntaxProtectionResult(markdown: output.joined(separator: "\n"), placeholders: placeholders)
        }

        private mutating func protectInlineSyntax(in line: String) -> String {
            var result = ""
            result.reserveCapacity(line.count)

            var i = line.startIndex
            while i < line.endIndex {
                if let span = backtickSpan(in: line, at: i) {
                    result += protect(String(line[i..<span]), kind: .inlineCode)
                    i = span
                    continue
                }

                if let span = autolinkSpan(in: line, at: i) {
                    result += protect(String(line[i..<span]), kind: .autolink)
                    i = span
                    continue
                }

                if let match = markdownInlineLinkOrImageSpan(in: line, at: i) {
                    result += protect(String(line[i..<match.end]), kind: match.kind)
                    i = match.end
                    continue
                }

                if let span = urlSpan(in: line, at: i) {
                    result += protect(String(line[i..<span]), kind: .url)
                    i = span
                    continue
                }

                if let span = filePathSpan(in: line, at: i) {
                    result += protect(String(line[i..<span]), kind: .filePath)
                    i = span
                    continue
                }

                result.append(line[i])
                i = line.index(after: i)
            }

            return result
        }

        private mutating func protect(_ original: String, kind: MarkdownSyntaxIslandKind) -> String {
            let token = "\(placeholderPrefix)\(placeholders.count)X"
            placeholders.append((placeholder: token, original: original, kind: kind))
            return token
        }

        private static func makePlaceholderPrefix(avoiding source: String) -> String {
            for salt in 0..<10_000 {
                let prefix = "SCOPYMARKDOWNSYNTAX\(salt)"
                if !source.contains(prefix) { return prefix }
            }
            return "SCOPYMARKDOWNSYNTAX\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        }

        private func isReferenceDefinitionLine(_ line: String) -> Bool {
            let leadingSpaces = MarkdownCodeSkipper.leadingIndentSpaces(in: line)
            guard leadingSpaces <= 3 else { return false }
            let trimmed = String(line.dropFirst(min(leadingSpaces, line.count)))
            guard trimmed.first == "[" else { return false }
            guard let close = matchingClose(in: String(trimmed), openIndex: trimmed.startIndex, open: "[", close: "]") else {
                return false
            }
            let afterClose = trimmed.index(after: close)
            guard afterClose < trimmed.endIndex else { return false }
            return trimmed[afterClose] == ":"
        }

        private func backtickSpan(in line: String, at index: String.Index) -> String.Index? {
            guard line[index] == "`" else { return nil }

            var runEnd = index
            var runCount = 0
            while runEnd < line.endIndex, line[runEnd] == "`" {
                runCount += 1
                runEnd = line.index(after: runEnd)
            }

            var i = runEnd
            while i < line.endIndex {
                guard line[i] == "`" else {
                    i = line.index(after: i)
                    continue
                }

                var closeEnd = i
                var closeCount = 0
                while closeEnd < line.endIndex, line[closeEnd] == "`" {
                    closeCount += 1
                    closeEnd = line.index(after: closeEnd)
                }
                if closeCount == runCount { return closeEnd }
                i = closeEnd
            }

            return nil
        }

        private func autolinkSpan(in line: String, at index: String.Index) -> String.Index? {
            guard line[index] == "<" else { return nil }
            let next = line.index(after: index)
            guard next < line.endIndex else { return nil }
            let tail = String(line[next...]).lowercased()
            guard tail.hasPrefix("http://") || tail.hasPrefix("https://") || tail.hasPrefix("mailto:") else { return nil }
            guard let close = line[next...].firstIndex(of: ">") else { return nil }
            let body = line[next..<close]
            guard !body.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
            return line.index(after: close)
        }

        private func markdownInlineLinkOrImageSpan(
            in line: String,
            at index: String.Index
        ) -> (end: String.Index, kind: MarkdownSyntaxIslandKind)? {
            var labelOpen = index
            var kind: MarkdownSyntaxIslandKind = .inlineLink

            if line[index] == "!" {
                let next = line.index(after: index)
                guard next < line.endIndex, line[next] == "[" else { return nil }
                labelOpen = next
                kind = .image
            } else {
                guard line[index] == "[" else { return nil }
            }

            guard let labelClose = matchingClose(in: line, openIndex: labelOpen, open: "[", close: "]") else {
                return nil
            }

            let afterLabel = line.index(after: labelClose)
            guard afterLabel < line.endIndex else { return nil }

            if line[afterLabel] == "(",
               let destinationClose = matchingClose(in: line, openIndex: afterLabel, open: "(", close: ")") {
                return (line.index(after: destinationClose), kind)
            }

            if line[afterLabel] == "[",
               let referenceClose = matchingClose(in: line, openIndex: afterLabel, open: "[", close: "]") {
                return (line.index(after: referenceClose), .referenceLink)
            }

            return nil
        }

        private func urlSpan(in line: String, at index: String.Index) -> String.Index? {
            let tail = String(line[index...]).lowercased()
            guard tail.hasPrefix("http://") || tail.hasPrefix("https://") else { return nil }
            return consumeUntilBoundary(in: line, from: index)
        }

        private func filePathSpan(in line: String, at index: String.Index) -> String.Index? {
            let tail = String(line[index...])
            let lowerTail = tail.lowercased()
            guard tail.hasPrefix("/Users/")
                || tail.hasPrefix("/Volumes/")
                || tail.hasPrefix("~/")
                || tail.hasPrefix("./")
                || tail.hasPrefix("../")
                || lowerTail.hasPrefix("file://")
            else {
                return nil
            }
            return consumeUntilBoundary(in: line, from: index)
        }

        private func consumeUntilBoundary(in line: String, from index: String.Index) -> String.Index {
            var i = index
            while i < line.endIndex {
                let ch = line[i]
                if ch.isWhitespace || ch.isNewline { break }
                i = line.index(after: i)
            }
            return i
        }

        private func matchingClose(
            in text: String,
            openIndex: String.Index,
            open: Character,
            close: Character
        ) -> String.Index? {
            guard openIndex < text.endIndex, text[openIndex] == open else { return nil }

            var depth = 1
            var i = text.index(after: openIndex)
            while i < text.endIndex {
                let ch = text[i]
                if ch == "\\" {
                    let next = text.index(after: i)
                    i = next < text.endIndex ? text.index(after: next) : next
                    continue
                }
                if ch == "\n" { return nil }
                if ch == open {
                    depth += 1
                } else if ch == close {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i = text.index(after: i)
            }
            return nil
        }
    }
}
