import Foundation

struct MarkdownSafeHTMLExtractionResult {
    let markdown: String
    let fallbackMarkdown: String
    let replacements: [String: MarkdownSafeHTMLSubset.Replacement]
}

enum MarkdownSafeHTMLSubset {
    struct Replacement: Codable, Equatable {
        let kind: String
        let tag: String?
        let text: String?
        let isOpen: Bool?
        let summary: String?
        let body: String?
    }

    static func extract(from markdown: String) -> MarkdownSafeHTMLExtractionResult {
        Extractor(source: markdown).process(markdown)
    }

    private final class Extractor {
        private let commentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->", options: [])
        private let detailsRegex = try! NSRegularExpression(pattern: "<details(\\s+open)?\\s*>([\\s\\S]*?)</details>", options: [.caseInsensitive])
        private let summaryRegex = try! NSRegularExpression(pattern: "<summary\\s*>([\\s\\S]*?)</summary>", options: [.caseInsensitive])
        private let inlineTagRegex = try! NSRegularExpression(pattern: "<(u|kbd|mark|sub|sup)>([\\s\\S]*?)</\\1>", options: [.caseInsensitive])
        private let placeholderSalt: String
        private let placeholderPrefix: String

        private var counter = 0
        private var replacements: [String: Replacement] = [:]

        init(source: String) {
            let salt = Self.makePlaceholderSalt(avoiding: source)
            self.placeholderSalt = salt
            self.placeholderPrefix = "SCOPYSAFEHTMLPLACEHOLDER\(salt)"
        }

        func process(_ source: String) -> MarkdownSafeHTMLExtractionResult {
            let protectedBlocks = protectFencedCodeBlocks(in: source)
            var working = protectedBlocks.markdown
            working = commentRegex.stringByReplacingMatches(
                in: working,
                options: [],
                range: NSRange(working.startIndex..., in: working),
                withTemplate: ""
            )

            var fallback = working
            replaceDetails(in: &working, fallback: &fallback)
            replaceInlineTags(in: &working, fallback: &fallback)

            let restoredMarkdown = restoreProtectedBlocks(in: working, from: protectedBlocks.placeholders)
            let restoredFallback = restoreProtectedBlocks(in: fallback, from: protectedBlocks.placeholders)
            return MarkdownSafeHTMLExtractionResult(
                markdown: restoredMarkdown,
                fallbackMarkdown: restoredFallback,
                replacements: replacements
            )
        }

        private struct ProtectedBlocks {
            let markdown: String
            let placeholders: [String: String]
        }

        private func protectFencedCodeBlocks(in source: String) -> ProtectedBlocks {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var output: [String] = []
            var protected: [String: String] = [:]
            var activeFence: (marker: Character, count: Int, token: String, lines: [String])?

            for line in lines {
                if let fence = MarkdownCodeSkipper.fencePrefix(in: line) {
                    if var current = activeFence {
                        current.lines.append(line)
                        if current.marker == fence.0, fence.1 >= current.count {
                            protected[current.token] = current.lines.joined(separator: "\n")
                            output.append(current.token)
                            activeFence = nil
                        } else {
                            activeFence = current
                        }
                        continue
                    }

                    activeFence = (marker: fence.0, count: fence.1, token: nextToken(prefix: "SCOPYSAFECODE"), lines: [line])
                    continue
                }

                if var current = activeFence {
                    current.lines.append(line)
                    activeFence = current
                    continue
                }

                output.append(line)
            }

            if let current = activeFence {
                protected[current.token] = current.lines.joined(separator: "\n")
                output.append(current.token)
            }

            return ProtectedBlocks(markdown: output.joined(separator: "\n"), placeholders: protected)
        }

        private func restoreProtectedBlocks(in source: String, from placeholders: [String: String]) -> String {
            var restored = source
            for (token, original) in placeholders {
                restored = restored.replacingOccurrences(of: token, with: original)
            }
            return restored
        }

        private func replaceDetails(in working: inout String, fallback: inout String) {
            while let match = detailsRegex.firstMatch(in: working, options: [], range: NSRange(working.startIndex..., in: working)),
                  let wholeRange = Range(match.range(at: 0), in: working),
                  let bodyRange = Range(match.range(at: 2), in: working) {
                let originalWorking = working
                let inner = String(working[bodyRange])
                let originalBlock = String(originalWorking[wholeRange])
                let summary: String
                let summaryFallback: String
                let body: String
                let bodyFallback: String

                if let summaryMatch = summaryRegex.firstMatch(in: inner, options: [], range: NSRange(inner.startIndex..., in: inner)),
                   let summaryRange = Range(summaryMatch.range(at: 1), in: inner),
                   let summaryWholeRange = Range(summaryMatch.range(at: 0), in: inner) {
                    let processedSummary = process(String(inner[summaryRange]))
                    var remainingBody = inner
                    remainingBody.replaceSubrange(summaryWholeRange, with: "")
                    let processedBody = process(remainingBody)
                    summary = processedSummary.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    summaryFallback = processedSummary.fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    body = processedBody.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    bodyFallback = processedBody.fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let processedBody = process(inner)
                    summary = ""
                    summaryFallback = ""
                    body = processedBody.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    bodyFallback = processedBody.fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let openRange = match.range(at: 1)
                let token = nextToken()
                replacements[token] = Replacement(
                    kind: "details",
                    tag: nil,
                    text: nil,
                    isOpen: openRange.location != NSNotFound,
                    summary: summary,
                    body: body
                )

                let fallbackText = [summaryFallback, bodyFallback]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")

                if let fallbackWholeRange = fallback.range(of: originalBlock) {
                    fallback.replaceSubrange(fallbackWholeRange, with: fallbackText)
                }
                working = originalWorking.replacingCharacters(in: wholeRange, with: "\n\n\(token)\n\n")
            }
        }

        private func replaceInlineTags(in working: inout String, fallback: inout String) {
            let workingLines = working.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let fallbackSourceLines = fallback.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let lineCount = max(workingLines.count, fallbackSourceLines.count)
            var transformedLines: [String] = []
            var fallbackLines: [String] = []
            transformedLines.reserveCapacity(lineCount)
            fallbackLines.reserveCapacity(lineCount)

            for index in 0..<lineCount {
                let workingLine = index < workingLines.count ? workingLines[index] : ""
                var fallbackLine = index < fallbackSourceLines.count ? fallbackSourceLines[index] : workingLine
                let transformed = MarkdownCodeSkipper.processInlineCode(in: workingLine) { segment in
                    replaceInlineTags(in: segment, fallback: &fallbackLine)
                }
                transformedLines.append(transformed)
                fallbackLines.append(fallbackLine)
            }

            working = transformedLines.joined(separator: "\n")
            fallback = fallbackLines.joined(separator: "\n")
        }

        private func replaceInlineTags(in segment: String, fallback: inout String) -> String {
            var output = segment

            while let match = inlineTagRegex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
                  let wholeRange = Range(match.range(at: 0), in: output),
                  let tagRange = Range(match.range(at: 1), in: output),
                  let textRange = Range(match.range(at: 2), in: output) {
                let tag = String(output[tagRange]).lowercased()
                let text = String(output[textRange])
                let token = nextToken()
                replacements[token] = Replacement(
                    kind: "inlineTag",
                    tag: tag,
                    text: text,
                    isOpen: nil,
                    summary: nil,
                    body: nil
                )
                output.replaceSubrange(wholeRange, with: token)
            }

            fallback = inlineTagRegex.stringByReplacingMatches(
                in: fallback,
                options: [],
                range: NSRange(fallback.startIndex..., in: fallback),
                withTemplate: "$2"
            )
            return output
        }

        private func nextToken(prefix: String = "SCOPYSAFEHTMLPLACEHOLDER") -> String {
            defer { counter += 1 }
            if prefix == "SCOPYSAFEHTMLPLACEHOLDER" {
                return "\(placeholderPrefix)\(counter)X"
            }
            return "\(prefix)\(placeholderSalt)\(counter)X"
        }

        private static func makePlaceholderSalt(avoiding source: String) -> String {
            for _ in 0..<8 {
                let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                if !source.contains("SCOPYSAFEHTMLPLACEHOLDER\(salt)"),
                   !source.contains("SCOPYSAFECODE\(salt)") {
                    return salt
                }
            }
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }
}
