import CryptoKit
import Foundation

import ScopyKit

/// The per-item enrichment artifact, keyed by the markdown content hash. Immutable once
/// written; regenerating requires deleting the sidecar (it is a derived cache, not truth).
struct LinkEnrichmentPayload: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version: Int
    var fetchedAt: Date
    var entries: [String: LinkEnrichmentEntry] {
        didSet { fingerprint = Self.fingerprint(of: entries) }
    }

    /// Participates in render and metric cache keys so a pre-enrichment DOM is never
    /// mistaken for the enriched one. Computed once per entries value: entries can carry
    /// data-URI images, and render keys read this on every preview update.
    private(set) var fingerprint: String

    private enum CodingKeys: String, CodingKey {
        case version, fetchedAt, entries
    }

    init(version: Int, fetchedAt: Date, entries: [String: LinkEnrichmentEntry]) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.entries = entries
        self.fingerprint = Self.fingerprint(of: entries)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(Int.self, forKey: .version),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            entries: try container.decode([String: LinkEnrichmentEntry].self, forKey: .entries)
        )
    }

    private static func fingerprint(of entries: [String: LinkEnrichmentEntry]) -> String {
        // An empty result set renders identically to no sidecar at all, so it must not
        // perturb render keys and force a visually identical re-render.
        guard !entries.isEmpty else { return "plain" }
        // JSONEncoder's key order is not stable across calls; sorted keys make the digest a
        // function of the entries alone.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hasher = SHA256()
        for key in entries.keys.sorted() {
            hasher.update(data: Data(key.utf8))
            if let data = try? encoder.encode(entries[key]) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum LinkEnrichmentContentKey {
    static func make(for markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Notification.Name {
    static let scopyLinkEnrichmentDidUpdate = Notification.Name("ScopyLinkEnrichmentDidUpdate")
}

enum LinkEnrichmentNotificationKey {
    static let contentKey = "contentKey"
}
