import Foundation

enum MarkdownATXHeadingNormalizer {
    /// Best-effort: normalize ATX headings like `##标题` -> `## 标题`.
    /// Some Markdown sources omit the CommonMark-required space after `#`, which makes
    /// heading lines fall back to paragraph rendering and inherit the wrong inline styles.
    static func normalize(_ markdown: String) -> String {
        guard markdown.contains("#") else { return markdown }

        var out: [String] = []
        out.reserveCapacity(markdown.split(separator: "\n", omittingEmptySubsequences: false).count)

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
                out.append(line)
                continue
            }

            if inFence != nil {
                out.append(line)
                continue
            }

            // Avoid altering indented code blocks.
            var i = line.startIndex
            var leadingSpaces = 0
            while i < line.endIndex, line[i] == " " {
                leadingSpaces += 1
                i = line.index(after: i)
            }
            if leadingSpaces > 3 {
                out.append(line)
                continue
            }

            guard i < line.endIndex, line[i] == "#" else {
                out.append(line)
                continue
            }

            var j = i
            var hashCount = 0
            while j < line.endIndex, line[j] == "#" {
                hashCount += 1
                j = line.index(after: j)
            }

            guard (1...6).contains(hashCount), j < line.endIndex else {
                out.append(line)
                continue
            }

            let next = line[j]
            if next == " " || next == "\t" {
                out.append(line)
                continue
            }
            // Avoid shebang-like patterns in plain text.
            if hashCount == 1, next == "!" {
                out.append(line)
                continue
            }

            let prefix = String(line[..<j])
            let rest = String(line[j...])
            out.append(prefix + " " + rest)
        }

        return out.joined(separator: "\n")
    }
}
