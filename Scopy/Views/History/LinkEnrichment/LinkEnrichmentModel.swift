import CryptoKit
import Foundation

/// One frozen Open Graph snapshot for a link in an assistant copy. Imagery is stored as
/// bounded data URIs so the rendered envelope stays self-contained and passes the same
/// strict v2 data-image limits as every other rich surface.
struct LinkEnrichmentEntry: Codable, Equatable, Sendable {
    var title: String
    var source: String?
    var date: String?
    var snippet: String?
    var image: String?
    var favicon: String?
}

/// The per-item enrichment artifact, keyed by the markdown content hash. Immutable once
/// written; regenerating requires deleting the sidecar (it is a derived cache, not truth).
struct LinkEnrichmentPayload: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version: Int
    var fetchedAt: Date
    var entries: [String: LinkEnrichmentEntry]

    /// Participates in render and metric cache keys so a pre-enrichment DOM is never
    /// mistaken for the enriched one.
    var fingerprint: String {
        var hasher = SHA256()
        for key in entries.keys.sorted() {
            hasher.update(data: Data(key.utf8))
            if let data = try? JSONEncoder().encode(entries[key]) {
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
