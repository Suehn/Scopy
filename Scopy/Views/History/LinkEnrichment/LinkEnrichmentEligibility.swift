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
            guard let url = bareLinkURL(onLine: String(line)) else { continue }
            guard !isNonArticleHost(url), seen.insert(url).inserted else { continue }
            results.append(url)
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
    private static func bareLinkURL(onLine line: String) -> String? {
        let pattern = #"^\s*(?:[-*]\s+)?\[[^\]\[]+\]\((https?://[^\s()]+)\)\s*$"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(line[match])
        guard let urlRange = matched.range(of: #"https?://[^\s()]+"#, options: .regularExpression) else { return nil }
        return String(matched[urlRange])
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
