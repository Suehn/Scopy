import Foundation

enum FTSQueryBuilder {
    /// Build a safe FTS5 query from user input.
    ///
    /// Notes:
    /// - We intentionally strip `*` to avoid expensive prefix scans unless explicitly supported.
    /// - Whitespace-separated tokens are combined with `AND` (more robust than treating the whole query as a phrase).
    static func build(userQuery: String) -> String? {
        let trimmed = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")

        let parts = normalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        if parts.isEmpty { return nil }

        if parts.count == 1 {
            return quotePhrase(parts[0])
        }

        return parts.map(quotePhrase).joined(separator: " AND ")
    }

    private static func quotePhrase(_ raw: String) -> String {
        // Escape quotes inside phrase per FTS5 syntax: "" inside "..."
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
