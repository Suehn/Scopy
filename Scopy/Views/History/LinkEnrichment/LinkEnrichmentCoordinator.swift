import Foundation

/// Orchestrates opt-in link enrichment: one idempotent ensure per markdown content key,
/// with in-flight de-duplication. On completion the frozen payload is persisted (even when
/// empty, so ineligible or unreachable content is not re-fetched on every hover) and a
/// notification lets the visible preview re-render with the enriched context.
actor LinkEnrichmentCoordinator {
    static let shared = LinkEnrichmentCoordinator()

    private var inFlight: Set<String> = []
    private let store: LinkEnrichmentStore
    private let fetcher: LinkEnrichmentFetcher

    init(store: LinkEnrichmentStore = .shared, fetcher: LinkEnrichmentFetcher = LinkEnrichmentFetcher()) {
        self.store = store
        self.fetcher = fetcher
    }

    /// Called from the preview path whenever the user has enabled link enrichment.
    func ensureEnrichment(markdown: String) async {
        let contentKey = LinkEnrichmentContentKey.make(for: markdown)
        guard store.payload(forContentKey: contentKey) == nil, !inFlight.contains(contentKey) else { return }
        let urls = LinkEnrichmentEligibility.candidateURLs(in: markdown)
        inFlight.insert(contentKey)
        defer { inFlight.remove(contentKey) }

        let entries = urls.isEmpty ? [:] : await fetcher.enrich(urls: urls)
        let payload = LinkEnrichmentPayload(
            version: LinkEnrichmentPayload.formatVersion,
            fetchedAt: Date(),
            entries: entries
        )
        store.write(payload, forContentKey: contentKey)
        guard !entries.isEmpty else { return }
        NotificationCenter.default.post(
            name: .scopyLinkEnrichmentDidUpdate,
            object: nil,
            userInfo: [LinkEnrichmentNotificationKey.contentKey: contentKey]
        )
    }
}
