import Foundation

enum MathProtector {
    struct ProtectedMath {
        let markdown: String
        let placeholders: [(placeholder: String, original: String)]
    }

    // Keep this bounded for hover preview.
    private static let maxInputUTF16Count = 200_000
    private static let maxInlineMathUTF16Count = 2_000
    private static let maxBlockMathUTF16Count = 8_000

    /// Protects math regions from Markdown parsing, then later restore them into HTML as plain text.
    ///
    /// Why this exists:
    /// - Markdown parsers do not treat `$...$` as a special "math" region, so characters like `_` or `*`
    ///   inside math often get parsed as emphasis, breaking KaTeX auto-render.
    ///
    /// Strategy:
    /// - Outside fenced code blocks and inline code spans, replace recognized math segments with stable
    ///   alphanumeric placeholders (so Markdown won't touch them).
    /// - After Markdown->HTML conversion, replace placeholders back with the original segment (HTML-escaped).
    static func protectMath(in markdown: String) -> ProtectedMath {
        guard markdown.utf16.count <= maxInputUTF16Count else {
            return ProtectedMath(markdown: markdown, placeholders: [])
        }

        var placeholders: [(String, String)] = []
        placeholders.reserveCapacity(16)

        var outputLines: [String] = []
        outputLines.reserveCapacity(markdown.split(separator: "\n", omittingEmptySubsequences: false).count)

        var inFencedCodeBlock = false
        var fenceMarker: Character? = nil
        var fenceCount = 0

        var inDisplayDollarBlock = false
        var displayDollarIndentSpaces = 0
        var displayDollarLines: [String] = []
        var displayDollarUTF16Count = 0
        displayDollarLines.reserveCapacity(16)

        var inEnvironmentBlock = false
        var environmentName: String = ""
        var environmentIndentSpaces = 0
        var environmentLines: [String] = []
        var environmentUTF16Count = 0
        environmentLines.reserveCapacity(32)

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

            // Multi-line LaTeX environments:
            // \begin{equation}
            //   ...
            // \end{equation}
            if let beginName = environmentBeginName(in: line), !inEnvironmentBlock {
                inEnvironmentBlock = true
                environmentName = beginName
                environmentIndentSpaces = min(3, leadingIndentSpaces(in: line))
                environmentLines.removeAll(keepingCapacity: true)
                environmentLines.append(line)
                environmentUTF16Count = line.utf16.count

                if line.contains("\\end{\(environmentName)}") {
                    let original = normalizeMathSegment(environmentLines.joined(separator: "\n"))
                    let placeholder = nextPlaceholder(index: placeholders.count)
                    placeholders.append((placeholder, original))
                    let indent = String(repeating: " ", count: environmentIndentSpaces)
                    outputLines.append(indent + placeholder)
                    inEnvironmentBlock = false
                    environmentName = ""
                    environmentIndentSpaces = 0
                    environmentLines.removeAll(keepingCapacity: true)
                    environmentUTF16Count = 0
                }
                continue
            }

            if inEnvironmentBlock {
                if environmentUTF16Count + line.utf16.count > maxBlockMathUTF16Count * 8 {
                    outputLines.append(contentsOf: environmentLines)
                    inEnvironmentBlock = false
                    environmentName = ""
                    environmentIndentSpaces = 0
                    environmentLines.removeAll(keepingCapacity: true)
                    environmentUTF16Count = 0
                    // fallthrough to process current line normally below.
                } else {
                    environmentLines.append(line)
                    environmentUTF16Count += line.utf16.count
                    if line.contains("\\end{\(environmentName)}") {
                        let original = normalizeMathSegment(environmentLines.joined(separator: "\n"))
                        let placeholder = nextPlaceholder(index: placeholders.count)
                        placeholders.append((placeholder, original))
                        let indent = String(repeating: " ", count: environmentIndentSpaces)
                        outputLines.append(indent + placeholder)
                        inEnvironmentBlock = false
                        environmentName = ""
                        environmentIndentSpaces = 0
                        environmentLines.removeAll(keepingCapacity: true)
                        environmentUTF16Count = 0
                    }
                    continue
                }
            }

            // Multi-line display math blocks:
            // $$
            //   ...
            // $$
            if isDisplayDollarDelimiterLine(line) {
                if inDisplayDollarBlock {
                    displayDollarLines.append(line)
                    displayDollarUTF16Count += line.utf16.count
                    let original = normalizeMathSegment(displayDollarLines.joined(separator: "\n"))
                    let placeholder = nextPlaceholder(index: placeholders.count)
                    placeholders.append((placeholder, original))
                    // Emit with clamped indentation (<= 3 spaces) to avoid Markdown treating it as an indented code block.
                    let indent = String(repeating: " ", count: min(3, max(0, displayDollarIndentSpaces)))
                    outputLines.append(indent + placeholder)
                    inDisplayDollarBlock = false
                    displayDollarIndentSpaces = 0
                    displayDollarLines.removeAll(keepingCapacity: true)
                    displayDollarUTF16Count = 0
                } else {
                    inDisplayDollarBlock = true
                    displayDollarIndentSpaces = min(3, leadingIndentSpaces(in: line))
                    displayDollarLines.removeAll(keepingCapacity: true)
                    displayDollarLines.append(line)
                    displayDollarUTF16Count = line.utf16.count
                }
                continue
            }

            if inDisplayDollarBlock {
                // Keep bounded to avoid pathological cases.
                if displayDollarUTF16Count + line.utf16.count > maxBlockMathUTF16Count * 4 {
                    // Give up on protecting this block; flush what we have and continue normally.
                    outputLines.append(contentsOf: displayDollarLines)
                    inDisplayDollarBlock = false
                    displayDollarIndentSpaces = 0
                    displayDollarLines.removeAll(keepingCapacity: true)
                    displayDollarUTF16Count = 0
                    // fallthrough: process current line normally below.
                } else {
                    displayDollarLines.append(line)
                    displayDollarUTF16Count += line.utf16.count
                    continue
                }
            }

            line = processInlineCode(in: line) { segment in
                protectMathInPlainTextSegment(segment, placeholders: &placeholders)
            }
            outputLines.append(line)
        }

        if inDisplayDollarBlock, !displayDollarLines.isEmpty {
            // Unclosed block: keep original lines.
            outputLines.append(contentsOf: displayDollarLines)
        }

        if inEnvironmentBlock, !environmentLines.isEmpty {
            outputLines.append(contentsOf: environmentLines)
        }

        return ProtectedMath(markdown: outputLines.joined(separator: "\n"), placeholders: placeholders)
    }

    /// Restores placeholders into HTML as escaped text.
    static func restoreMath(in html: String, placeholders: [(placeholder: String, original: String)], escape: (String) -> String) -> String {
        guard !placeholders.isEmpty else { return html }
        var out = html
        for (placeholder, original) in placeholders {
            out = out.replacingOccurrences(of: placeholder, with: escape(original))
        }
        return out
    }

    // MARK: - Implementation

    private static func fencePrefix(in line: String) -> (Character, Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else { break }
        }
        return count >= 3 ? (first, count) : nil
    }

    private static func isDisplayDollarDelimiterLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "$$"
    }

    private static func environmentBeginName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\begin{") else { return nil }
        guard let close = trimmed.firstIndex(of: "}") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: "\\begin{".count)
        let name = String(trimmed[start..<close])
        // Keep it scoped to environments we explicitly support in auto-render delimiters.
        let supported: Set<String> = [
            "equation", "equation*",
            "align", "align*",
            "aligned",
            "cases",
            "gather", "gather*",
            "multline", "multline*",
            "split"
        ]
        return supported.contains(name) ? name : nil
    }

    private static func leadingIndentSpaces(in line: String) -> Int {
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

    private static func nextPlaceholder(index: Int) -> String {
        // Alnum only to avoid Markdown emphasis parsing.
        "SCOPYMATHPLACEHOLDER\(index)X"
    }

    private static func protectMathInPlainTextSegment(_ text: String, placeholders: inout [(String, String)]) -> String {
        // Fast path.
        guard text.contains("$") || text.contains("\\") else { return text }

        var out = disambiguateDoubleDollars(text)
        out = removeStrayDollarsBeforeTeXCommands(out)

        // 1) Protect environments (multi-line variants are usually already line-wrapped from OCR/PDF extract).
        // We do this before $ detection so environments inside $...$ are handled by $ protection.
        out = protectEnvironment(out, name: "equation", placeholders: &placeholders)
        out = protectEnvironment(out, name: "equation*", placeholders: &placeholders)
        out = protectEnvironment(out, name: "align", placeholders: &placeholders)
        out = protectEnvironment(out, name: "align*", placeholders: &placeholders)
        out = protectEnvironment(out, name: "aligned", placeholders: &placeholders)
        out = protectEnvironment(out, name: "cases", placeholders: &placeholders)
        out = protectEnvironment(out, name: "gather", placeholders: &placeholders)
        out = protectEnvironment(out, name: "gather*", placeholders: &placeholders)
        out = protectEnvironment(out, name: "multline", placeholders: &placeholders)
        out = protectEnvironment(out, name: "multline*", placeholders: &placeholders)
        out = protectEnvironment(out, name: "split", placeholders: &placeholders)

        // 2) Protect \(...\) and \[...\]
        out = protectDelimited(out, left: "\\(", right: "\\)", maxInnerUTF16: maxInlineMathUTF16Count, placeholders: &placeholders)
        out = protectDelimited(out, left: "\\[", right: "\\]", maxInnerUTF16: maxBlockMathUTF16Count, placeholders: &placeholders)

        // 3) Protect $$...$$ (same line only here; multi-line $$ in plain-text segment is uncommon)
        out = protectDollarMath(out, isBlock: true, maxInnerUTF16: maxBlockMathUTF16Count, placeholders: &placeholders)

        // 4) Protect $...$
        out = protectDollarMath(out, isBlock: false, maxInnerUTF16: maxInlineMathUTF16Count, placeholders: &placeholders)

        return out
    }

    /// PDF/Word extraction sometimes inserts stray `$` right before a TeX command inside what should still be one math run.
    ///
    /// Example:
    /// - `$... \\quad $\\mathbf{b} ...` is typically intended as `$... \\quad \\mathbf{b} ...`
    private static func removeStrayDollarsBeforeTeXCommands(_ text: String) -> String {
        guard text.contains("$"), text.contains("\\") else { return text }

        // Keep it conservative: only known spacing commands that are very unlikely to appear outside math.
        let commands = ["\\quad", "\\qquad", "\\,", "\\;", "\\:", "\\!"]

        var out = ""
        out.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$" {
                let after = text.index(after: i)
                if after < text.endIndex, text[after] == "\\" {
                    var j = i
                    while j > text.startIndex {
                        let prev = text.index(before: j)
                        if text[prev].isWhitespace {
                            j = prev
                            continue
                        }
                        break
                    }

                    let prefix = text[..<j]
                    if commands.contains(where: { prefix.hasSuffix($0) }) {
                        // Drop the `$` and keep the TeX command intact.
                        i = after
                        continue
                    }
                }
            }

            out.append(text[i])
            i = text.index(after: i)
        }

        return out
    }

    /// Disambiguate `$$` that were produced by adjacent inline math segments (common in PDF/Word extraction),
    /// so we don't accidentally treat them as block math delimiters.
    ///
    /// Example:
    /// - `$\\mathbf{b}$$\\in$` is usually intended as `$\\mathbf{b}$ $\\in$`.
    private static func disambiguateDoubleDollars(_ text: String) -> String {
        guard text.contains("$$") else { return text }

        var out = ""
        out.reserveCapacity(text.count + 8)

        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "$" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "$" {
                    let prevChar: Character? = i > text.startIndex ? text[text.index(before: i)] : nil
                    let afterNext = text.index(after: next)
                    let nextChar: Character? = afterNext < text.endIndex ? text[afterNext] : nil

                    let prevIsBoundary = prevChar == nil || prevChar?.isWhitespace == true
                    let nextIsBoundary = nextChar == nil || nextChar?.isWhitespace == true

                    if !prevIsBoundary && !nextIsBoundary {
                        // Inline adjacency: likely close + open, but sometimes the second `$` is just an artifact:
                        // - `...$x$$,` should be `...$x$,`
                        if let nextChar, isLikelyPunctuation(nextChar) {
                            out.append("$")
                        } else {
                            out.append("$")
                            out.append(" ")
                            out.append("$")
                        }
                    } else {
                        // Likely block delimiter.
                        out.append("$")
                        out.append("$")
                    }
                    i = afterNext
                    continue
                }
            }
            out.append(text[i])
            i = text.index(after: i)
        }

        return out
    }

    private static func isLikelyPunctuation(_ ch: Character) -> Bool {
        switch ch {
        case ",", ".", ";", ":", "?", "!", ")", "]", "}", "，", "。", "；", "：", "？", "！", "）", "】", "、":
            return true
        default:
            return false
        }
    }

    private static func protectEnvironment(_ text: String, name: String, placeholders: inout [(String, String)]) -> String {
        let left = "\\begin{\(name)}"
        let right = "\\end{\(name)}"
        return protectDelimited(text, left: left, right: right, maxInnerUTF16: maxBlockMathUTF16Count, placeholders: &placeholders)
    }

    private static func protectDelimited(
        _ text: String,
        left: String,
        right: String,
        maxInnerUTF16: Int,
        placeholders: inout [(String, String)]
    ) -> String {
        guard text.contains(left), text.contains(right) else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            guard let start = text.range(of: left, range: i..<text.endIndex)?.lowerBound else {
                result += text[i..<text.endIndex]
                break
            }

            result += text[i..<start]
            let innerStart = text.index(start, offsetBy: left.count)

            guard let endRange = text.range(of: right, range: innerStart..<text.endIndex) else {
                result += text[start..<text.endIndex]
                break
            }

            let innerEnd = endRange.lowerBound
            let innerUTF16 = text[innerStart..<innerEnd].utf16.count
            if innerUTF16 == 0 || innerUTF16 > maxInnerUTF16 {
                result += text[start..<endRange.upperBound]
                i = endRange.upperBound
                continue
            }

            let original = normalizeMathSegment(String(text[start..<endRange.upperBound]))
            let placeholder = nextPlaceholder(index: placeholders.count)
            placeholders.append((placeholder, original))
            result += placeholder
            i = endRange.upperBound
        }

        return result
    }

    private static func protectDollarMath(
        _ text: String,
        isBlock: Bool,
        maxInnerUTF16: Int,
        placeholders: inout [(String, String)]
    ) -> String {
        let delimiter = isBlock ? "$$" : "$"
        guard text.contains(delimiter) else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            guard let start = findDollarDelimiter(in: text, delimiter: delimiter, from: i, isBlock: isBlock) else {
                result += text[i..<text.endIndex]
                break
            }

            result += text[i..<start]
            let afterStart = text.index(start, offsetBy: delimiter.count)

            guard let end = findDollarDelimiter(in: text, delimiter: delimiter, from: afterStart, isBlock: isBlock) else {
                result += text[start..<text.endIndex]
                break
            }

            // Do not allow newlines for inline $...$; block $$...$$ is still kept single-line in this segment.
            let inner = text[afterStart..<end]
            if !isBlock, inner.contains("\n") {
                result += text[start..<text.index(after: start)]
                i = text.index(after: start)
                continue
            }

            let innerUTF16 = inner.utf16.count
            if innerUTF16 == 0 || innerUTF16 > maxInnerUTF16 {
                result += text[start..<text.index(after: start)]
                i = text.index(after: start)
                continue
            }

            let endAfter = text.index(end, offsetBy: delimiter.count)
            var original = String(text[start..<endAfter])
            if !isBlock {
                let innerString = String(inner)
                // PDF/Word extraction sometimes loses \\begin{aligned} but keeps `&`. Upgrade to aligned.
                if innerString.contains("&"), innerString.contains("\\"), !innerString.contains("\\begin{") {
                    original = "$$\\begin{aligned} \(innerString) \\end{aligned}$$"
                }
            }
            let placeholder = nextPlaceholder(index: placeholders.count)
            placeholders.append((placeholder, normalizeMathSegment(original)))
            result += placeholder
            i = endAfter
        }

        return result
    }

    private static func findDollarDelimiter(in text: String, delimiter: String, from index: String.Index, isBlock: Bool) -> String.Index? {
        guard let range = text.range(of: delimiter, range: index..<text.endIndex) else { return nil }
        // Ignore escaped dollars.
        let start = range.lowerBound
        if start > text.startIndex {
            let prev = text[text.index(before: start)]
            if prev == "\\" {
                return findDollarDelimiter(in: text, delimiter: delimiter, from: range.upperBound, isBlock: isBlock)
            }
        }
        if isBlock, delimiter == "$$" {
            // Avoid treating adjacent `$...$$...$` artifacts as display math delimiters.
            let prevChar: Character? = start > text.startIndex ? text[text.index(before: start)] : nil
            let after = range.upperBound
            let nextChar: Character? = after < text.endIndex ? text[after] : nil
            let prevIsBoundary = prevChar == nil || prevChar?.isWhitespace == true || (prevChar.map(isLikelyPunctuation) ?? false)
            let nextIsBoundary = nextChar == nil || nextChar?.isWhitespace == true || (nextChar.map(isLikelyPunctuation) ?? false)
            if !prevIsBoundary && !nextIsBoundary {
                return findDollarDelimiter(in: text, delimiter: delimiter, from: range.upperBound, isBlock: isBlock)
            }
        }
        return start
    }

    private static func normalizeMathSegment(_ s: String) -> String {
        var out = normalizeEscapedTeXCommandsInMath(s)
        out = removeCommandWithSingleBracedArg(out, command: "\\label")
        out = normalizeSetBracesInMath(out)
        return out
    }

    private static func removeCommandWithSingleBracedArg(_ s: String, command: String) -> String {
        guard let (updated, _) = extractCommandWithSingleBracedArg(s, command: command) else { return s }
        return updated
    }

    private static func extractCommandWithSingleBracedArg(_ s: String, command: String) -> (String, String)? {
        guard let range = s.range(of: command) else { return nil }
        let afterCmd = range.upperBound
        guard afterCmd < s.endIndex, s[afterCmd] == "{" else { return nil }

        var i = s.index(after: afterCmd)
        var depth = 1
        var scanned = 0
        while i < s.endIndex, scanned < maxBlockMathUTF16Count {
            let c = s[i]
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            i = s.index(after: i)
            scanned += 1
        }
        guard i < s.endIndex, depth == 0 else { return nil }

        let arg = String(s[s.index(after: afterCmd)..<i])
        let afterArg = s.index(after: i)

        // Remove surrounding whitespace/newlines when deleting the command to avoid leaving blank lines.
        var left = range.lowerBound
        while left > s.startIndex {
            let prev = s[s.index(before: left)]
            if prev == " " || prev == "\t" { left = s.index(before: left); continue }
            break
        }
        var right = afterArg
        while right < s.endIndex {
            let ch = s[right]
            if ch == " " || ch == "\t" { right = s.index(after: right); continue }
            if ch == "\n" {
                right = s.index(after: right)
                break
            }
            break
        }

        var updated = s
        updated.replaceSubrange(left..<right, with: "")
        return (updated, arg)
    }

    /// Best-effort: text copied from JSON / code often contains `\\command` instead of `\command`.
    /// Inside math this usually means a single escaped backslash, not a TeX linebreak.
    private static func normalizeEscapedTeXCommandsInMath(_ s: String) -> String {
        guard s.contains("\\\\") else { return s }
        var out = ""
        out.reserveCapacity(s.count)

        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" {
                var j = i
                var run = 0
                while j < s.endIndex, s[j] == "\\" {
                    run += 1
                    j = s.index(after: j)
                    if run >= 8 { break }
                }
                if run >= 2, j < s.endIndex, s[j].isLetter {
                    out.append("\\")
                } else {
                    for _ in 0..<run {
                        out.append("\\")
                    }
                }
                i = j
                continue
            }

            out.append(s[i])
            i = s.index(after: i)
        }

        return out
    }

    /// Convert `={...}` set notation to `=\\{...\\}` when it likely represents literal curly braces.
    /// Example: `\\mathcal{N}_u={i\\mid (u,i)\\in\\mathcal{E}}`.
    private static func normalizeSetBracesInMath(_ s: String) -> String {
        guard s.contains("={") else { return s }

        var out = ""
        out.reserveCapacity(s.count + 8)

        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "=" {
                let braceStart = s.index(after: i)
                if braceStart < s.endIndex, s[braceStart] == "{" {
                    var j = s.index(after: braceStart)
                    var depth = 1
                    var scanned = 0
                    while j < s.endIndex, scanned < maxBlockMathUTF16Count {
                        let c = s[j]
                        if c == "{" { depth += 1 }
                        if c == "}" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        j = s.index(after: j)
                        scanned += 1
                    }

                    if j < s.endIndex, depth == 0 {
                        let inner = String(s[s.index(after: braceStart)..<j])
                        if (inner.contains("\\mid") || inner.contains("|")),
                           !inner.contains("\\{"), !inner.contains("\\}")
                        {
                            out.append("=")
                            out.append("\\")
                            out.append("{")
                            out += inner
                            out.append("\\")
                            out.append("}")
                            i = s.index(after: j)
                            continue
                        }
                    }
                }
            }

            out.append(s[i])
            i = s.index(after: i)
        }

        return out
    }
}
