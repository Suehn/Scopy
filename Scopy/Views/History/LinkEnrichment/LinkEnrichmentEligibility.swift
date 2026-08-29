import Foundation

/// Decides whether a markdown item is assistant-shaped content whose degraded links may be
/// enriched, and extracts the exact candidate URLs. Recognition must cover ChatGPT web
/// copies, Codex output, and similar assistant markdown, while ordinary prose stays out.
enum LinkEnrichmentEligibility {
    static let maximumCandidateURLs = 13

    static func candidateURLs(in markdown: String) -> [String] {
        guard isAssistantContent(markdown) else { return [] }
        var seen = Set<String>()
        var results: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let link = bareLink(onLine: String(line)) else { continue }
            guard !isNonArticleHost(link.url), seen.insert(link.url).inserted else { continue }
            guard link.label.unicodeScalars.count <= 64 else { continue }
            results.append(link.url)
            if results.count == maximumCandidateURLs { break }
        }
        return results
    }

    /// Assistant-content gate. Signals, any one of which qualifies:
    /// - links rewritten by ChatGPT's share/copy path (`utm_source=chatgpt.com`);
    /// - Codex-style absolute local file destinations;
    /// - reference-style source citations plus real markdown structure.
    static func isAssistantContent(_ markdown: String) -> Bool {
        let sample = String(markdown.prefix(80_000))
        if sample.contains("utm_source=chatgpt.com") { return true }
        if sample.contains("](/Users/") || sample.contains("](/Volumes/") || sample.contains("](~/") {
            return true
        }
        let hasReferenceDefinitions = sample.range(of: #"(?m)^\[[^\]]+\]:\s+https?://"#, options: .regularExpression) != nil
        let hasCitationGroups = sample.range(of: #"\(\[[^\]]+\]\[[^\]]+\]"#, options: .regularExpression) != nil
        let hasHeadings = sample.range(of: #"(?m)^#{1,6}\s"#, options: .regularExpression) != nil
        return (hasReferenceDefinitions || hasCitationGroups) && hasHeadings
    }

    /// A line that is exactly one markdown link (optionally as a `-`/`*` list item):
    /// the degraded shape ChatGPT's Copy leaves behind for news and lone articles.
    /// Markdown backslash escapes inside the destination (ChatGPT copies commonly write
    /// `\&` in query strings) are unescaped so the fetched URL matches the parsed AST URL.
    private static func bareLink(onLine line: String) -> (label: String, url: String)? {
        let pattern = #"^\s*(?:[-*]\s+)?\[([^\]\[]+)\]\((https?://[^\s()]+)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 3,
              let labelRange = Range(match.range(at: 1), in: line),
              let urlRange = Range(match.range(at: 2), in: line)
        else { return nil }
        let url = unescapeMarkdownPunctuation(String(line[urlRange]))
        return (String(line[labelRange]), url)
    }

    private static func unescapeMarkdownPunctuation(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var previousWasBackslash = false
        for character in value {
            if previousWasBackslash {
                if !character.isASCII || character.isLetter || character.isNumber {
                    result.append("\\")
                }
                result.append(character)
                previousWasBackslash = false
            } else if character == "\\" {
                previousWasBackslash = true
            } else {
                result.append(character)
            }
        }
        if previousWasBackslash { result.append("\\") }
        return result
    }

    /// Hosts whose lone links already have a dedicated presentation (video cards) or are
    /// unlikely to carry article metadata worth a request.
    private static func isNonArticleHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return true }
        let excluded: Set<String> = [
            "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
            "localhost"
        ]
        if excluded.contains(host) || host.hasSuffix(".local") { return true }
        return false
    }
}
