import AppKit
import Foundation

extension ClipboardMonitor {
    // MARK: - Helper Methods

    /// Chooses between the pasteboard `.string` and the text extracted from the rich payload.
    ///
    /// Prefer the pasteboard-provided `.string` when it is a faithful plain-text representation of the rich
    /// payload. Some apps provide `.string` that is already a lossy transformation (e.g. rich -> Markdown), which
    /// can corrupt TeX-heavy content; in those cases, fall back to the text extracted from the rich payload.
    nonisolated private static func preferredPlainText(candidate: String?, extracted: String?, type: ClipboardItemType) -> String {
        let candidate = candidate ?? ""
        if candidate.isEmpty {
            return extracted ?? ""
        }

        guard let extracted, !extracted.isEmpty else {
            return candidate
        }

        if Self.normalizeText(candidate) == Self.normalizeText(extracted) {
            return candidate
        }

        // Some producers place the authored Markdown in `text/plain` and its rendered copy in `text/html`.
        // Preserve that source representation when it is clearly Markdown and the HTML-derived text confirms
        // that both payloads describe the same content. The HTML payload itself remains the stored rich payload.
        if type == .html, Self.isClearlyStructuredMarkdown(candidate) {
            if Self.textRepresentationsAreRelated(candidate, extracted) {
                return candidate
            }
            return extracted
        }

        // If the extracted text is TeX-heavy and the pasteboard `.string` differs materially from it, prefer the
        // extracted version to avoid storing a transformed/Markdown-converted representation.
        if Self.containsTeXCommands(extracted) {
            return extracted
        }

        return candidate
    }

    /// Whether HTML extraction can produce TeX, including delimiters synthesized from math annotations.
    nonisolated private static func mayContainTeXCharacters(htmlData: Data, string: String?) -> Bool {
        if let string, string.contains("\\") || string.contains("$") {
            return true
        }
        let backslash = UInt8(ascii: "\\"), dollar = UInt8(ascii: "$"), ampersand = UInt8(ascii: "&"), hash = UInt8(ascii: "#")
        var previous: UInt8 = 0
        for byte in htmlData {
            if byte == backslash || byte == dollar { return true }
            if previous == ampersand, byte == hash { return true }
            previous = byte
        }
        // Math annotations such as `E = mc^2` need extraction even without literal TeX delimiters.
        if let text = Self.decodeHTMLDataToString(htmlData) {
            if text.range(of: "application/x-tex", options: .caseInsensitive) != nil
                || text.range(of: "&dollar", options: .caseInsensitive) != nil
                || text.range(of: "&bsol", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }

    /// Text-representation extraction off the main thread. RTF import, normalization and the Markdown/TeX
    /// heuristics run here; the WebKit HTML import must run on the main thread and is requested only when
    /// it can change the stored text.
    nonisolated static func makeTextRawData(
        rtfData: Data?,
        htmlData: Data?,
        string: String?,
        appBundleID: String?,
        parseHTMLOnMain: @MainActor @Sendable (Data) -> String?
    ) async -> RawClipboardData? {
        // 3. RTF
        if let rtfData {
            let rtfPlainText = Self.normalizeText(
                Self.preferredPlainText(candidate: string, extracted: Self.extractPlainTextFromRTF(rtfData), type: .rtf)
            )
            var plainText = rtfPlainText
            if let htmlData {
                // The HTML text can only win when the RTF text is empty or fragmented, or when TeX may be
                // involved (`shouldPreferRichPlainText`); otherwise the 0.3-0.7 s/MB HTML import is skipped.
                let htmlTextCanWin = rtfPlainText.isEmpty
                    || Self.isLikelyFragmentedCopyText(rtfPlainText)
                    || Self.mayContainTeXCharacters(htmlData: htmlData, string: string)
                if htmlTextCanWin {
                    let extracted = await parseHTMLOnMain(htmlData)
                    let htmlPlainText = Self.normalizeText(
                        Self.preferredPlainText(candidate: string, extracted: extracted, type: .html)
                    )
                    if Self.shouldPreferRichPlainText(htmlPlainText, over: rtfPlainText) {
                        plainText = htmlPlainText
                    }
                }
            }
            return RawClipboardData(
                type: .rtf,
                plainText: plainText,
                rawData: rtfData,
                appBundleID: appBundleID,
                sizeBytes: rtfData.count
            )
        }

        // 4. HTML
        if let htmlData {
            let candidate = string ?? ""
            // `preferredPlainText` returns the pasteboard string unless it is empty, is authored Markdown,
            // or the HTML text carries TeX; only those cases need the import.
            let needsImport = candidate.isEmpty
                || Self.isClearlyStructuredMarkdown(candidate)
                || Self.mayContainTeXCharacters(htmlData: htmlData, string: string)
            let plainText: String
            if needsImport {
                let extracted = await parseHTMLOnMain(htmlData)
                plainText = Self.normalizeText(Self.preferredPlainText(candidate: string, extracted: extracted, type: .html))
            } else {
                plainText = Self.normalizeText(candidate)
            }
            return RawClipboardData(
                type: .html,
                plainText: plainText,
                rawData: htmlData,
                appBundleID: appBundleID,
                sizeBytes: htmlData.count
            )
        }

        // 5. Plain text (最低优先级 - 作为兜底)
        if let string {
            let normalizedText = Self.normalizeText(string)
            return RawClipboardData(
                type: .text,
                plainText: normalizedText,
                rawData: nil,
                appBundleID: appBundleID,
                sizeBytes: normalizedText.utf8.count
            )
        }
        return nil
    }

    nonisolated private static func isClearlyStructuredMarkdown(_ text: String) -> Bool {
        // This is intentionally stricter than preview eligibility. Clipboard MIME selection should only override
        // rich-text extraction for unambiguous source Markdown, not prose that happens to contain punctuation.
        let sample = text.count > 64_000 ? String(text.prefix(64_000)) : text
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)

        var score = 0
        var listItemCount = 0
        var blockquoteCount = 0
        var fenceCount = 0
        var sawTableRow = false
        var sawTableDelimiter = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenceCount += 1
            }
            if Self.isATXHeading(line) {
                score += 2
            }
            if Self.isMarkdownListItem(line) {
                listItemCount += 1
            }
            if line.hasPrefix("> ") {
                blockquoteCount += 1
            }
            if line.contains("|") {
                sawTableRow = true
                if Self.isMarkdownTableDelimiter(line) {
                    sawTableDelimiter = true
                }
            }
        }

        if fenceCount >= 2 { score += 2 }
        if listItemCount >= 2 { score += 2 } else if listItemCount == 1 { score += 1 }
        if blockquoteCount >= 2 { score += 2 } else if blockquoteCount == 1 { score += 1 }
        if sawTableRow && sawTableDelimiter { score += 2 }
        if Self.containsPairedMarkdownMarker("**", in: sample) || Self.containsPairedMarkdownMarker("__", in: sample) {
            score += 1
        }
        if Self.containsMarkdownLink(in: sample) { score += 2 }
        if Self.containsPairedMarkdownMarker("$$", in: sample)
            || (sample.contains("\\(") && sample.contains("\\)"))
            || (sample.contains("\\[") && sample.contains("\\]")) {
            score += 2
        }

        return score >= 2
    }

    nonisolated private static func isATXHeading(_ line: String) -> Bool {
        let markerCount = line.prefix { $0 == "#" }.count
        guard (1...6).contains(markerCount), line.count > markerCount else { return false }
        return line[line.index(line.startIndex, offsetBy: markerCount)].isWhitespace
    }

    nonisolated private static func isMarkdownListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }

        var index = line.startIndex
        var digitCount = 0
        while index < line.endIndex, line[index].isNumber, digitCount < 9 {
            digitCount += 1
            index = line.index(after: index)
        }
        guard digitCount > 0, index < line.endIndex, line[index] == "." else { return false }
        index = line.index(after: index)
        return index < line.endIndex && line[index].isWhitespace
    }

    nonisolated private static func isMarkdownTableDelimiter(_ line: String) -> Bool {
        let cells = line.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    nonisolated private static func containsPairedMarkdownMarker(_ marker: String, in text: String) -> Bool {
        guard let first = text.range(of: marker) else { return false }
        return text[first.upperBound...].range(of: marker) != nil
    }

    nonisolated private static func containsMarkdownLink(in text: String) -> Bool {
        guard let closeBracket = text.range(of: "](") else { return false }
        return text[..<closeBracket.lowerBound].contains("[")
            && text[closeBracket.upperBound...].contains(")")
    }

    nonisolated private static func textRepresentationsAreRelated(_ candidate: String, _ extracted: String) -> Bool {
        let candidateTokens = Self.comparisonTokens(in: candidate)
        let extractedTokens = Self.comparisonTokens(in: extracted)
        guard candidateTokens.count >= 2, extractedTokens.count >= 2 else { return false }

        var candidateCounts: [String: Int] = [:]
        candidateCounts.reserveCapacity(candidateTokens.count)
        for token in candidateTokens {
            candidateCounts[token, default: 0] += 1
        }

        var commonCount = 0
        for token in extractedTokens {
            guard let count = candidateCounts[token], count > 0 else { continue }
            commonCount += 1
            candidateCounts[token] = count - 1
        }

        let extractedCoverage = Double(commonCount) / Double(extractedTokens.count)
        let candidateCoverage = Double(commonCount) / Double(candidateTokens.count)
        return extractedCoverage >= 0.75 && candidateCoverage >= 0.65
    }

    nonisolated private static func comparisonTokens(in text: String) -> [String] {
        let bounded = text.count > 64_000 ? String(text.prefix(64_000)) : text
        let sample = Self.strippingInlineMarkdownDestinations(bounded)
        var tokens: [String] = []
        tokens.reserveCapacity(min(sample.count / 5, 8_192))
        var current = ""

        for character in sample.lowercased() {
            // Ideographs do not need spaces between words. Rich extraction may join table cells
            // or strip emphasis inside a sentence; neither should change their comparison units.
            if character.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                tokens.append(String(character))
            } else if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    nonisolated private static func strippingInlineMarkdownDestinations(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "]", next < text.endIndex, text[next] == "(" {
                var cursor = text.index(after: next)
                var depth = 1
                var isEscaped = false

                while cursor < text.endIndex {
                    let character = text[cursor]
                    let after = text.index(after: cursor)
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "(" {
                        depth += 1
                    } else if character == ")" {
                        depth -= 1
                        if depth == 0 {
                            result.append("]")
                            index = after
                            break
                        }
                    }
                    cursor = after
                }

                if depth == 0 {
                    continue
                }
            }

            result.append(text[index])
            index = next
        }

        return result
    }

    nonisolated private static func containsTeXCommands(_ text: String) -> Bool {
        // Heuristic: detect common TeX signals so we can prefer an extracted rich payload representation
        // over a corrupted pasteboard `.string` (e.g. KaTeX/MathML selection from web pages).
        if !text.contains("\\") && !text.contains("$") {
            return false
        }

        var sawBackslash = false
        var dollarCount = 0
        for ch in text {
            if ch == "$" {
                dollarCount += 1
                if dollarCount >= 2 { return true }
            }

            if sawBackslash {
                if ch.isLetter { return true } // \frac, \varepsilon, ...
                if ch == "(" || ch == "[" || ch == ")" || ch == "]" { return true } // \( \) \[ \]
                sawBackslash = false
                continue
            }

            if ch == "\\" {
                sawBackslash = true
            }
        }

        return false
    }

    nonisolated private static func shouldPreferRichPlainText(_ candidate: String, over baseline: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if baseline.isEmpty { return true }

        if Self.containsTeXCommands(candidate), !Self.containsTeXCommands(baseline) {
            return true
        }

        if Self.isLikelyFragmentedCopyText(baseline), !Self.isLikelyFragmentedCopyText(candidate) {
            return true
        }

        return false
    }

    nonisolated private static func isLikelyFragmentedCopyText(_ text: String) -> Bool {
        // Typical symptom when copying KaTeX-rendered equations as plain text: a lot of 1-2 character lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 8 else { return false }

        var shortLineCount = 0
        for line in lines {
            if line.count <= 2 { shortLineCount += 1 }
        }

        return Double(shortLineCount) / Double(lines.count) >= 0.6
    }

    /// Normalize text for consistent hashing (v0.md 3.2: 去首尾空白、统一换行)
    nonisolated private static func normalizeText(_ text: String) -> String {
        text
            // Normalize common Unicode line separators to '\n' for stable hashing (still "统一换行").
            .replacingOccurrences(of: "\u{2028}", with: "\n") // LINE SEPARATOR
            .replacingOccurrences(of: "\u{2029}", with: "\n") // PARAGRAPH SEPARATOR
            .replacingOccurrences(of: "\u{0085}", with: "\n") // NEXT LINE
            // Normalize NBSP/BOM that commonly appear in PDF/web copies.
            .replacingOccurrences(of: "\u{00A0}", with: " ")  // NO-BREAK SPACE
            .replacingOccurrences(of: "\u{FEFF}", with: "")   // BOM / ZERO WIDTH NO-BREAK SPACE
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    nonisolated private static func extractPlainTextFromRTF(_ data: Data) -> String? {
        guard let attributedString = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }
        return attributedString.string
    }

    func extractPlainTextFromHTML(_ data: Data) -> String? {
        if let html = Self.decodeHTMLDataToString(data),
           html.range(of: "application/x-tex", options: .caseInsensitive) != nil {
            let extracted = Self.extractMarkdownLikeTextFromKaTeXHTML(html)
            if !extracted.isEmpty {
                return extracted
            }
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html
        ]
        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return attributedString.string
    }

    nonisolated private static func decodeHTMLDataToString(_ data: Data) -> String? {
        // In practice pasteboard HTML is usually UTF-8, but some producers emit UTF-16.
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            .isoLatin1,
            .windowsCP1252
        ]

        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }

        return nil
    }

    nonisolated private static func extractMarkdownLikeTextFromKaTeXHTML(_ html: String) -> String {
        // Fast path: avoid work when there's no KaTeX marker.
        if !html.localizedCaseInsensitiveContains("katex") {
            return ""
        }

        var output = ""
        output.reserveCapacity(min(html.utf8.count, 16_384))

        var index = html.startIndex
        var inKaTeX = false
        var kaTeXSpanDepth = 0
        var kaTeXIsDisplay = false

        var inAnnotation = false
        var annotationIsDisplay = false
        var annotationBuffer = ""

        while index < html.endIndex {
            guard let tagStart = html[index...].firstIndex(of: "<") else {
                let tail = String(html[index...])
                Self.appendHTMLText(tail, to: &output, inKaTeX: inKaTeX, inAnnotation: &inAnnotation, annotationBuffer: &annotationBuffer)
                break
            }

            let textSegment = String(html[index..<tagStart])
            Self.appendHTMLText(textSegment, to: &output, inKaTeX: inKaTeX, inAnnotation: &inAnnotation, annotationBuffer: &annotationBuffer)

            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else { break }
            let rawTag = String(html[html.index(after: tagStart)..<tagEnd])
            index = html.index(after: tagEnd)

            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { continue }
            if tag.hasPrefix("!--") { continue }

            let isClosing = tag.hasPrefix("/")
            let tagBody = isClosing ? tag.dropFirst() : Substring(tag)
            let tagName = tagBody
                .prefix { !$0.isWhitespace && $0 != "/" }
                .lowercased()

            if tagName.isEmpty { continue }

            if inAnnotation {
                if isClosing, tagName == "annotation" {
                    let tex = Self.decodeHTMLEntities(annotationBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                    annotationBuffer = ""
                    inAnnotation = false

                    if !tex.isEmpty {
                        if annotationIsDisplay {
                            Self.appendNewlines(1, to: &output)
                            output.append("$$\n")
                            output.append(tex)
                            output.append("\n$$")
                            Self.appendNewlines(1, to: &output)
                        } else {
                            output.append("$")
                            output.append(tex)
                            output.append("$")
                        }
                    }
                }
                continue
            }

            switch tagName {
            case "br":
                Self.appendNewlines(1, to: &output)
            case "p", "div", "section", "article":
                if isClosing {
                    Self.appendNewlines(2, to: &output)
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if isClosing {
                    Self.appendNewlines(2, to: &output)
                } else if let level = Int(tagName.dropFirst()) {
                    Self.appendNewlines(output.isEmpty ? 0 : 2, to: &output)
                    output.append(String(repeating: "#", count: level))
                    output.append(" ")
                }
            case "li":
                if isClosing {
                    Self.appendNewlines(1, to: &output)
                } else {
                    Self.appendNewlines(output.isEmpty ? 0 : 1, to: &output)
                    output.append("- ")
                }
            case "annotation":
                if !isClosing,
                   Self.attribute(named: "encoding", in: tag)?.lowercased() == "application/x-tex" {
                    inAnnotation = true
                    annotationIsDisplay = kaTeXIsDisplay
                    annotationBuffer = ""
                }
            case "span":
                if isClosing {
                    if inKaTeX {
                        kaTeXSpanDepth -= 1
                        if kaTeXSpanDepth <= 0 {
                            inKaTeX = false
                            kaTeXSpanDepth = 0
                            kaTeXIsDisplay = false
                        }
                    }
                } else {
                    if inKaTeX {
                        kaTeXSpanDepth += 1
                    } else if let classAttr = Self.attribute(named: "class", in: tag),
                              classAttr.localizedCaseInsensitiveContains("katex") {
                        inKaTeX = true
                        kaTeXSpanDepth = 1
                        kaTeXIsDisplay = classAttr.localizedCaseInsensitiveContains("katex-display")
                    }
                }
            default:
                break
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func appendHTMLText(
        _ text: String,
        to output: inout String,
        inKaTeX: Bool,
        inAnnotation: inout Bool,
        annotationBuffer: inout String
    ) {
        guard !text.isEmpty else { return }
        if inAnnotation {
            annotationBuffer.append(text)
            return
        }
        if inKaTeX {
            return
        }

        let decoded = Self.decodeHTMLEntities(text)
        for ch in decoded {
            if ch.isWhitespace || ch.isNewline {
                if output.isEmpty { continue }
                if output.last == " " || output.last == "\n" { continue }
                output.append(" ")
            } else {
                output.append(ch)
            }
        }
    }

    nonisolated private static func appendNewlines(_ count: Int, to output: inout String) {
        guard count > 0 else { return }
        var trimmed = output
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        output = trimmed
        if output.isEmpty {
            output.append(String(repeating: "\n", count: count))
            return
        }

        let existingNewlines = output.reversed().prefix { $0 == "\n" }.count
        let needed = max(0, count - existingNewlines)
        if needed > 0 {
            output.append(String(repeating: "\n", count: needed))
        }
    }

    nonisolated private static func attribute(named name: String, in tag: String) -> String? {
        // Extremely small attribute parser: looks for name="..." or name='...'.
        // Tag is the raw content inside "<" and ">".
        let needle = "\(name.lowercased())="
        guard let range = tag.range(of: needle, options: [.caseInsensitive]) else { return nil }

        var i = range.upperBound
        while i < tag.endIndex, tag[i].isWhitespace {
            i = tag.index(after: i)
        }
        guard i < tag.endIndex else { return nil }

        let quote = tag[i]
        if quote == "\"" || quote == "'" {
            let start = tag.index(after: i)
            guard let end = tag[start...].firstIndex(of: quote) else { return nil }
            return String(tag[start..<end])
        }

        // Unquoted value: read until whitespace.
        let start = i
        var end = start
        while end < tag.endIndex, !tag[end].isWhitespace {
            end = tag.index(after: end)
        }
        return String(tag[start..<end])
    }

    nonisolated private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var output = ""
        output.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch != "&" {
                output.append(ch)
                index = text.index(after: index)
                continue
            }

            guard let semi = text[index...].firstIndex(of: ";") else {
                output.append(ch)
                index = text.index(after: index)
                continue
            }

            let entity = String(text[text.index(after: index)..<semi])
            if let decoded = Self.decodeHTMLEntity(entity) {
                output.append(decoded)
                index = text.index(after: semi)
                continue
            }

            output.append("&")
            index = text.index(after: index)
        }

        return output
    }

    nonisolated private static func decodeHTMLEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "#39", "apos": return "'"
        case "nbsp": return " "
        default:
            break
        }

        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            let hex = entity.dropFirst(2)
            if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                return String(Character(scalar))
            }
            return nil
        }

        if entity.hasPrefix("#") {
            let dec = entity.dropFirst()
            if let value = UInt32(dec, radix: 10), let scalar = UnicodeScalar(value) {
                return String(Character(scalar))
            }
            return nil
        }

        return nil
    }
}
