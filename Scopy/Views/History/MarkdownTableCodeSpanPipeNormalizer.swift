import Foundation

enum MarkdownTableCodeSpanPipeNormalizer {
    static func normalize(_ markdown: String) -> String {
        guard markdown.contains("|"), markdown.contains("`") else { return markdown }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return markdown }

        let tableLineIndexes = tableLineIndexes(in: lines)
        guard !tableLineIndexes.isEmpty else { return markdown }

        var output = lines
        for index in tableLineIndexes where output[index].contains("`") && output[index].contains("|") {
            output[index] = normalizeCodeSpans(in: output[index])
        }
        return output.joined(separator: "\n")
    }

    private static func tableLineIndexes(in lines: [String]) -> Set<Int> {
        var indexes = Set<Int>()
        var activeFence: (marker: Character, count: Int)?

        for index in lines.indices {
            let line = lines[index]
            if let fence = MarkdownCodeSkipper.fencePrefix(in: line) {
                if let active = activeFence {
                    if active.marker == fence.0, fence.1 >= active.count {
                        activeFence = nil
                    }
                } else {
                    activeFence = (marker: fence.0, count: fence.1)
                }
                continue
            }
            if activeFence != nil { continue }
            guard isTableDelimiterLine(line) else { continue }

            let headerIndex = index - 1
            if lines.indices.contains(headerIndex), isTableContentLine(lines[headerIndex]) {
                indexes.insert(headerIndex)
            }

            var bodyIndex = index + 1
            while lines.indices.contains(bodyIndex), isTableContentLine(lines[bodyIndex]) {
                indexes.insert(bodyIndex)
                bodyIndex += 1
            }
        }

        return indexes
    }

    private static func isTableDelimiterLine(_ line: String) -> Bool {
        guard MarkdownCodeSkipper.leadingIndentSpaces(in: line) <= 3 else { return false }
        guard line.contains("|") else { return false }

        var working = line.trimmingCharacters(in: .whitespaces)
        if working.first == "|" { working.removeFirst() }
        if working.last == "|" { working.removeLast() }
        let cells = working.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy(isDelimiterCell)
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        guard cell.count >= 3 else { return false }
        var body = cell
        if body.first == ":" { body.removeFirst() }
        if body.last == ":" { body.removeLast() }
        return body.count >= 3 && body.allSatisfy { $0 == "-" }
    }

    private static func isTableContentLine(_ line: String) -> Bool {
        MarkdownCodeSkipper.leadingIndentSpaces(in: line) <= 3 && line.contains("|")
    }

    private static func normalizeCodeSpans(in line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)

        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "`" else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            let openEnd = backtickRunEnd(in: line, from: index)
            let runCount = line.distance(from: index, to: openEnd)
            guard runCount <= 2 else {
                result += String(line[index..<openEnd])
                index = openEnd
                continue
            }
            guard let closeStart = matchingBacktickRunStart(in: line, from: openEnd, runCount: runCount) else {
                result.append(line[index])
                index = line.index(after: index)
                continue
            }

            let closeEnd = line.index(closeStart, offsetBy: runCount)
            result += String(line[index..<openEnd])
            result += escapeUnescapedPipes(String(line[openEnd..<closeStart]))
            result += String(line[closeStart..<closeEnd])
            index = closeEnd
        }

        return result
    }

    private static func backtickRunEnd(in line: String, from start: String.Index) -> String.Index {
        var index = start
        while index < line.endIndex, line[index] == "`" {
            index = line.index(after: index)
        }
        return index
    }

    private static func matchingBacktickRunStart(
        in line: String,
        from start: String.Index,
        runCount: Int
    ) -> String.Index? {
        var index = start
        while index < line.endIndex {
            guard line[index] == "`" else {
                index = line.index(after: index)
                continue
            }

            let runEnd = backtickRunEnd(in: line, from: index)
            if line.distance(from: index, to: runEnd) == runCount {
                return index
            }
            index = runEnd
        }
        return nil
    }

    private static func escapeUnescapedPipes(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "|", !isEscaped(in: text, at: index) {
                result.append("\\")
            }
            result.append(text[index])
            index = text.index(after: index)
        }

        return result
    }

    private static func isEscaped(in text: String, at index: String.Index) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount % 2 == 1
    }
}
