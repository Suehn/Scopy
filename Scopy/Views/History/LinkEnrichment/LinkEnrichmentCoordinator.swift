import Foundation
import ScopyKit

/// Orchestrates opt-in link enrichment: one idempotent ensure per markdown content key,
/// with in-flight de-duplication. On completion the frozen payload is persisted (even when
/// empty, so ineligible or unreachable content is not re-fetched on every hover) and a
/// notification lets the visible preview re-render with the enriched context.
actor LinkEnrichmentCoordinator {
    static let shared = LinkEnrichmentCoordinator()
    private static let globalWorkPool = AsyncPermitPool(limit: 2, maxPending: 4)

    private var inFlight: Set<String> = []
    private let store: LinkEnrichmentStore
    private let fetcher: LinkEnrichmentFetcher
    private let workPool: AsyncPermitPool

    init(
        store: LinkEnrichmentStore = .shared,
        fetcher: LinkEnrichmentFetcher = LinkEnrichmentFetcher(),
        workPool: AsyncPermitPool = LinkEnrichmentCoordinator.globalWorkPool
    ) {
        self.store = store
        self.fetcher = fetcher
        self.workPool = workPool
    }

    /// Called from the preview path whenever the user has enabled link enrichment.
    func ensureEnrichment(markdown: String) async {
        let contentKey = LinkEnrichmentContentKey.make(for: markdown)
        guard store.payload(forContentKey: contentKey) == nil, !inFlight.contains(contentKey) else { return }
        let urls = LinkEnrichmentEligibility.candidateURLs(in: markdown)
        inFlight.insert(contentKey)
        defer { inFlight.remove(contentKey) }

        let entries: [String: LinkEnrichmentEntry]
        if urls.isEmpty {
            entries = [:]
        } else {
            guard await workPool.acquire() else { return }
            entries = await fetcher.enrich(urls: urls)
            await workPool.release()
        }
        guard !Task.isCancelled else { return }
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
