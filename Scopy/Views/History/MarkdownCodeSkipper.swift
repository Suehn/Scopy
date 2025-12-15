import Foundation

enum MarkdownCodeSkipper {
    static func fencePrefix(in line: String) -> (Character, Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        return count >= 3 ? (first, count) : nil
    }

    static func processInlineCode(in line: String, transform: (String) -> String) -> String {
        guard line.contains("`") else { return transform(line) }

        var result = ""
        result.reserveCapacity(line.count)

        var i = line.startIndex
        var inCode = false
        var backtickCount = 0
        var segmentStart = i

        func flushSegment(to end: String.Index) {
            let segment = String(line[segmentStart..<end])
            result += inCode ? segment : transform(segment)
        }

        while i < line.endIndex {
            if line[i] == "`" {
                // Count backticks run.
                var j = i
                var run = 0
                while j < line.endIndex, line[j] == "`" {
                    run += 1
                    j = line.index(after: j)
                }

                flushSegment(to: i)
                result += String(repeating: "`", count: run)

                if !inCode {
                    inCode = true
                    backtickCount = run
                } else if run == backtickCount {
                    inCode = false
                    backtickCount = 0
                }

                i = j
                segmentStart = i
                continue
            }
            i = line.index(after: i)
        }

        flushSegment(to: line.endIndex)
        return result
    }

    static func leadingIndentSpaces(in line: String) -> Int {
        // Convert tabs to 4 spaces (best-effort) and clamp later.
        var spaces = 0
        for ch in line {
            if ch == " " {
                spaces += 1
                continue
            }
            if ch == "\t" {
                spaces += 4
                continue
            }
            break
        }
        return spaces
    }
}

