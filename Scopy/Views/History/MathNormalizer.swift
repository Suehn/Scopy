import Foundation

enum MathNormalizer {
    // Keep this conservative to avoid false positives (e.g. Windows/macOS paths like \Users\...).
    private static let knownCommands: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
        "mathcal", "mathbb", "mathrm", "mathbf", "mathit", "mathsf", "mathtt",
        "text", "frac", "dfrac", "tfrac", "sqrt",
        "sum", "prod", "int", "iint", "iiint",
        "in", "notin", "mid", "cup", "cap", "setminus", "subset", "subseteq", "supset", "supseteq",
        "times", "cdot", "cdots", "ldots",
        "le", "leq", "ge", "geq", "neq", "approx", "sim",
        "to", "mapsto", "leftarrow", "rightarrow", "leftrightarrow", "Leftarrow", "Rightarrow", "Leftrightarrow",
        "land", "lor", "neg", "forall", "exists",
        // Intentionally exclude \\begin/\\end: they are handled by KaTeX environment delimiters + MathProtector.
    ]

    /// Wraps "loose LaTeX" fragments into KaTeX-friendly delimiters.
    ///
    /// Motivation: text extracted from PDF/Word often contains TeX commands like `(\mathcal{U})`
    /// without explicit math delimiters. KaTeX auto-render requires delimiters, so we add `$...$`
    /// around likely math fragments.
    ///
    /// Safety/perf constraints:
    /// - Only touches non-code regions (fenced code blocks + inline backticks are excluded).
    /// - Only wraps short, single-line bracketed fragments or short standalone commands.
    /// - Skips anything that already contains `$` or `\\(` / `\\[` delimiters.
    static func wrapLooseLaTeX(_ markdown: String) -> String {
        guard markdown.contains("\\") else { return markdown }
        // Keep this bounded; hover preview should never spend time "fixing" huge payloads.
        if markdown.utf16.count > 200_000 { return markdown }

        var outputLines: [String] = []
        outputLines.reserveCapacity(markdown.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFencedCodeBlock = false
        var fenceMarker: Character? = nil
        var fenceCount = 0

        // Some sources use display-math blocks like:
        // [
        //   ...TeX...
        // ]
        // Normalize to $$ ... $$ so KaTeX auto-render can handle it.
        var inBracketDisplayBlock = false
        var bracketIndentSpaces = 0
        var bracketLines: [String] = []
        bracketLines.reserveCapacity(16)

        for lineSub in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(lineSub)

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

            if isBracketDisplayDelimiterLine(line, expected: "[") {
                if inBracketDisplayBlock {
                    // Nested/duplicate start: flush as-is and restart.
                    outputLines.append(contentsOf: bracketLines)
                    bracketLines.removeAll(keepingCapacity: true)
                }
                inBracketDisplayBlock = true
                bracketIndentSpaces = min(3, leadingIndentSpaces(in: line))
                bracketLines.append(line)
                continue
            }

            if inBracketDisplayBlock {
                bracketLines.append(line)
                if isBracketDisplayDelimiterLine(line, expected: "]") {
                    let inner = bracketLines.dropFirst().dropLast().joined(separator: "\n")
                    if shouldTreatAsDisplayMathBlock(inner) {
                        let indent = String(repeating: " ", count: bracketIndentSpaces)
                        outputLines.append(indent + "$$")
                        outputLines.append(contentsOf: inner.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                        outputLines.append(indent + "$$")
                    } else {
                        outputLines.append(contentsOf: bracketLines)
                    }
                    inBracketDisplayBlock = false
                    bracketIndentSpaces = 0
                    bracketLines.removeAll(keepingCapacity: true)
                }
                continue
            }

            line = processInlineCode(in: line) { segment in
                normalizePlainTextSegment(segment)
            }
            outputLines.append(line)
        }

        if inBracketDisplayBlock, !bracketLines.isEmpty {
            outputLines.append(contentsOf: bracketLines)
        }

        return outputLines.joined(separator: "\n")
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

    private static func isBracketDisplayDelimiterLine(_ line: String, expected: Character) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).count == 1
            && line.trimmingCharacters(in: .whitespacesAndNewlines).first == expected
    }

    private static func leadingIndentSpaces(in line: String) -> Int {
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

    private static func shouldTreatAsDisplayMathBlock(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.contains("$$") || s.contains("\\[") || s.contains("\\(") { return false }
        if s.utf16.count > 12_000 { return false }

        if containsKnownCommand(in: s) { return true }
        if s.contains("^") || s.contains("_") { return true }
        if s.contains("\\") && (s.contains("{") || s.contains("=")) { return true }
        return false
    }

    private static func processInlineCode(in line: String, transform: (String) -> String) -> String {
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

    private static func normalizePlainTextSegment(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        if text.contains("\\(") || text.contains("\\[") || text.contains("$$") { return text }

        var s = wrapBracketedMath(text, open: "(", close: ")", maxInnerLength: 320)
        s = wrapBracketedMath(s, open: "（", close: "）", maxInnerLength: 320)
        s = wrapBracketedMath(s, open: "[", close: "]", maxInnerLength: 320)
        s = wrapBracketedMath(s, open: "【", close: "】", maxInnerLength: 320)
        s = wrapStandaloneCommandsOutsideDollarMath(s, maxLength: 160)
        return s
    }

    private static func wrapBracketedMath(_ text: String, open: Character, close: Character, maxInnerLength: Int) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            guard ch == open else {
                result.append(ch)
                i = text.index(after: i)
                continue
            }

            // Find matching close on the same line within maxInnerLength.
            var j = text.index(after: i)
            var depth = 1
            var scanned = 0
            var found: String.Index? = nil
            while j < text.endIndex, scanned < maxInnerLength {
                let c = text[j]
                if c == "\n" { break }
                if c == open { depth += 1 }
                if c == close {
                    depth -= 1
                    if depth == 0 {
                        found = j
                        break
                    }
                }
                scanned += 1
                j = text.index(after: j)
            }

            guard let closeIndex = found else {
                result.append(ch)
                i = text.index(after: i)
                continue
            }

            let innerStart = text.index(after: i)
            let inner = String(text[innerStart..<closeIndex])

            if shouldWrapAsMath(inner) {
                // Prefer wrapping the whole bracket expression as one math segment.
                // This avoids `$...$` being split by surrounding punctuation and is more robust for KaTeX auto-render.
                if open == "(" || open == "（" {
                    result += "$\\left(\(inner)\\right)$"
                } else if open == "[" || open == "【" {
                    result += "$\\left[\(inner)\\right]$"
                } else {
                    result.append("$")
                    result.append(open)
                    result += inner
                    result.append(close)
                    result.append("$")
                }
            } else {
                result.append(open)
                result += inner
                result.append(close)
            }

            i = text.index(after: closeIndex)
        }

        return result
    }

    private static func wrapStandaloneCommandsOutsideDollarMath(_ text: String, maxLength: Int) -> String {
        guard text.contains("\\") else { return text }
        guard text.contains("$") else { return wrapStandaloneCommands(text, maxLength: maxLength) }

        var result = ""
        result.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "$" else {
                // Copy until next `$` (fast path).
                if let next = text[i...].firstIndex(of: "$") {
                    let chunk = String(text[i..<next])
                    result += wrapStandaloneCommands(chunk, maxLength: maxLength)
                    i = next
                    continue
                }
                let chunk = String(text[i..<text.endIndex])
                result += wrapStandaloneCommands(chunk, maxLength: maxLength)
                break
            }

            // Handle escaped dollars.
            if i > text.startIndex, text[text.index(before: i)] == "\\" {
                result.append("$")
                i = text.index(after: i)
                continue
            }

            // Detect delimiter (`$` or `$$`).
            let next = text.index(after: i)
            let isDouble = next < text.endIndex && text[next] == "$"
            let delimiter = isDouble ? "$$" : "$"
            let afterStart = isDouble ? text.index(after: next) : next

            if let end = findUnescapedDollarDelimiter(in: text, delimiter: delimiter, from: afterStart) {
                let endAfter = text.index(end, offsetBy: delimiter.count)
                result += text[i..<endAfter]
                i = endAfter
                continue
            }

            // Unclosed: treat the `$` as normal text.
            result.append("$")
            i = text.index(after: i)
        }

        return result
    }

    private static func findUnescapedDollarDelimiter(in text: String, delimiter: String, from index: String.Index) -> String.Index? {
        guard let range = text.range(of: delimiter, range: index..<text.endIndex) else { return nil }
        let start = range.lowerBound
        if start > text.startIndex, text[text.index(before: start)] == "\\" {
            return findUnescapedDollarDelimiter(in: text, delimiter: delimiter, from: range.upperBound)
        }
        return start
    }

    private static func wrapStandaloneCommands(_ text: String, maxLength: Int) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            guard ch == "\\" else {
                result.append(ch)
                i = text.index(after: i)
                continue
            }

            // Skip if already inside `$...$` by looking back one char (cheap heuristic).
            if i > text.startIndex {
                let prev = text[text.index(before: i)]
                if prev == "$" {
                    result.append(ch)
                    i = text.index(after: i)
                    continue
                }
            }

            var j = text.index(after: i)
            var name = ""
            while j < text.endIndex {
                let c = text[j]
                if c.isLetter {
                    name.append(c)
                    if name.count >= 32 { break }
                    j = text.index(after: j)
                    continue
                }
                break
            }

            if name.isEmpty || !knownCommands.contains(name) {
                result.append(ch)
                i = text.index(after: i)
                continue
            }

            // Capture a short "command expression": \name{...}{...} with optional ^/_ groups.
            var end = j
            var consumed = 0
            func consumeBalancedBraces(from start: String.Index) -> String.Index? {
                guard start < text.endIndex, text[start] == "{" else { return nil }
                var k = text.index(after: start)
                var depth = 1
                var local = 0
                while k < text.endIndex, local < maxLength {
                    let c = text[k]
                    if c == "{" { depth += 1 }
                    if c == "}" {
                        depth -= 1
                        if depth == 0 { return text.index(after: k) }
                    }
                    local += 1
                    k = text.index(after: k)
                }
                return nil
            }

            while end < text.endIndex, consumed < maxLength {
                let c = text[end]
                if c == "{" {
                    guard let newEnd = consumeBalancedBraces(from: end) else { break }
                    consumed += text.distance(from: end, to: newEnd)
                    end = newEnd
                    continue
                }
                if c == "^" || c == "_" {
                    let next = text.index(after: end)
                    if next < text.endIndex, text[next] == "{" {
                        guard let newEnd = consumeBalancedBraces(from: next) else { break }
                        consumed += text.distance(from: end, to: newEnd)
                        end = newEnd
                        continue
                    }
                    // single character exponent/subscript
                    let next2 = next < text.endIndex ? text.index(after: next) : next
                    consumed += text.distance(from: end, to: next2)
                    end = next2
                    continue
                }
                break
            }

            let expr = String(text[i..<end])
            if shouldWrapAsMath(expr) {
                result.append("$")
                result += expr
                result.append("$")
            } else {
                result += expr
            }
            i = end
        }

        return result
    }

    private static func shouldWrapAsMath(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.contains("$") { return false }
        if s.contains("\\(") || s.contains("\\[") { return false }
        if s.utf16.count > 400 { return false }
        if s.contains("http://") || s.contains("https://") { return false }

        // Must contain at least one known TeX command, or strong math signal.
        if containsKnownCommand(in: s) { return true }
        if s.contains("^") || s.contains("_") { return true }
        return false
    }

    private static func containsKnownCommand(in s: String) -> Bool {
        guard let idx = s.firstIndex(of: "\\") else { return false }
        var i = idx
        while i < s.endIndex {
            guard s[i] == "\\" else {
                i = s.index(after: i)
                continue
            }
            var j = s.index(after: i)
            var name = ""
            while j < s.endIndex {
                let c = s[j]
                if c.isLetter {
                    name.append(c)
                    if name.count >= 32 { break }
                    j = s.index(after: j)
                    continue
                }
                break
            }
            if !name.isEmpty, knownCommands.contains(name) {
                return true
            }
            i = j
        }
        return false
    }
}
