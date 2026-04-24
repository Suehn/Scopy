import Foundation

struct MarkdownCJKEmphasisNormalizationResult {
    let markdown: String
    let renderSentinel: String?
}

enum MarkdownCJKEmphasisNormalizer {
    private static let emphasisRegex = try! NSRegularExpression(
        pattern: #"(?<!\\)(\*{1,3})(.+?)(?<!\\)\1"#,
        options: []
    )

    static func normalize(_ markdown: String) -> MarkdownCJKEmphasisNormalizationResult {
        guard markdown.contains("*") else {
            return MarkdownCJKEmphasisNormalizationResult(markdown: markdown, renderSentinel: nil)
        }

        let sentinel = makeSentinel(notIn: markdown)
        var changed = false
        var output: [String] = []
        output.reserveCapacity(markdown.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFence: (marker: Character, count: Int)?
        for lineSub in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)

            if let (marker, count) = MarkdownCodeSkipper.fencePrefix(in: line) {
                if let current = inFence {
                    if current.marker == marker, count >= current.count {
                        inFence = nil
                    }
                } else {
                    inFence = (marker: marker, count: count)
                }
                output.append(line)
                continue
            }

            if inFence != nil {
                output.append(line)
                continue
            }

            let normalizedLine = MarkdownCodeSkipper.processInlineCode(in: line) { segment in
                let normalizedSegment = normalizeAsteriskEmphasis(in: segment, sentinel: sentinel)
                if normalizedSegment != segment {
                    changed = true
                }
                return normalizedSegment
            }
            output.append(normalizedLine)
        }

        guard changed else {
            return MarkdownCJKEmphasisNormalizationResult(markdown: markdown, renderSentinel: nil)
        }
        return MarkdownCJKEmphasisNormalizationResult(
            markdown: output.joined(separator: "\n"),
            renderSentinel: sentinel
        )
    }

    static func stripRenderSentinel(from text: String, sentinel: String?) -> String {
        guard let sentinel, !sentinel.isEmpty else { return text }
        return text.replacingOccurrences(of: sentinel, with: "")
    }

    private static func normalizeAsteriskEmphasis(in segment: String, sentinel: String) -> String {
        let matches = emphasisRegex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment))
        guard !matches.isEmpty else { return segment }

        var result = segment
        for match in matches.reversed() {
            guard let wholeRangeInSource = Range(match.range(at: 0), in: segment),
                  let delimiterRange = Range(match.range(at: 1), in: segment),
                  let innerRange = Range(match.range(at: 2), in: segment) else {
                continue
            }

            let inner = String(segment[innerRange])
            guard !inner.isEmpty else { continue }

            let needsLeadingSentinel = shouldPadLeading(
                inner: inner,
                beforeOpening: characterBefore(wholeRangeInSource.lowerBound, in: segment)
            )
            let needsTrailingSentinel = shouldPadTrailing(
                inner: inner,
                afterClosing: characterAfter(wholeRangeInSource.upperBound, in: segment)
            )
            guard needsLeadingSentinel || needsTrailingSentinel else { continue }

            guard let wholeRangeInResult = Range(match.range(at: 0), in: result) else { continue }

            let delimiter = String(segment[delimiterRange])
            var paddedInner = inner
            if needsLeadingSentinel {
                paddedInner = sentinel + paddedInner
            }
            if needsTrailingSentinel {
                paddedInner += sentinel
            }
            result.replaceSubrange(wholeRangeInResult, with: delimiter + paddedInner + delimiter)
        }

        return result
    }

    private static func shouldPadLeading(inner: String, beforeOpening: Character?) -> Bool {
        guard let beforeOpening,
              isCJKWordUnit(beforeOpening),
              let first = inner.first else {
            return false
        }
        return isPunctuationLike(first)
    }

    private static func shouldPadTrailing(inner: String, afterClosing: Character?) -> Bool {
        guard let afterClosing,
              isCJKWordUnit(afterClosing),
              let last = inner.last else {
            return false
        }
        return isPunctuationLike(last)
    }

    private static func characterBefore(_ index: String.Index, in text: String) -> Character? {
        guard index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    private static func characterAfter(_ index: String.Index, in text: String) -> Character? {
        guard index < text.endIndex else { return nil }
        return text[index]
    }

    private static func isPunctuationLike(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    private static func isCJKWordUnit(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isCJKWordUnit)
    }

    private static func isCJKWordUnit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2F800...0x2FA1F,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0x31F0...0x31FF,
             0x1100...0x11FF,
             0x3130...0x318F,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private static func makeSentinel(notIn markdown: String) -> String {
        var token = "SCOPYEMPHFIXTOKENX"
        while markdown.contains(token) {
            token = "SCOPYEMPHFIX\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))X"
        }
        return token
    }
}
