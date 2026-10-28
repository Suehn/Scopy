import Foundation
import ScopyKit

/// Orchestrates opt-in link enrichment: visible previews share one task per content key.
/// The last consumer cancels the task. On completion the frozen payload is persisted (even when
/// empty, so ineligible or unreachable content is not re-fetched on every hover) and a
/// notification lets the visible preview re-render with the enriched context.
actor LinkEnrichmentCoordinator {
    static let shared = LinkEnrichmentCoordinator()
    private static let globalWorkPool = AsyncPermitPool(limit: 2, maxPending: 4)

    private struct Flight {
        let task: Task<Void, Never>
        var consumers: Set<UUID>
    }
    private var flights: [String: Flight] = [:]
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
        guard !Task.isCancelled else { return }
        let contentKey = LinkEnrichmentContentKey.make(for: markdown)
        let consumer = UUID()
        let task: Task<Void, Never>
        if let flight = flights[contentKey] {
            task = flight.task
            flights[contentKey]?.consumers.insert(consumer)
        } else {
            task = Task { await self.fetchAndPersist(markdown: markdown, contentKey: contentKey) }
            flights[contentKey] = Flight(task: task, consumers: [consumer])
        }

        await withTaskCancellationHandler {
            await task.value
            release(contentKey: contentKey, consumer: consumer)
        } onCancel: {
            Task { await self.release(contentKey: contentKey, consumer: consumer) }
        }
    }

    private func release(contentKey: String, consumer: UUID) {
        // A cancelled flight may still be draining after its replacement is admitted.
        // Its consumer IDs cannot release or cancel that new same-key flight.
        guard flights[contentKey]?.consumers.remove(consumer) != nil else { return }
        if flights[contentKey]?.consumers.isEmpty == true {
            flights.removeValue(forKey: contentKey)?.task.cancel()
        }
    }

    private func fetchAndPersist(markdown: String, contentKey: String) async {
        guard await store.payload(forContentKey: contentKey) == nil, !Task.isCancelled else { return }
        let urls = LinkEnrichmentEligibility.candidateURLs(in: markdown)

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
        await store.write(payload, forContentKey: contentKey)
        guard !entries.isEmpty else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .scopyLinkEnrichmentDidUpdate,
                object: nil,
                userInfo: [LinkEnrichmentNotificationKey.contentKey: contentKey]
            )
        }
    }

    #if DEBUG
    func consumerCountForTesting(contentKey: String) -> Int {
        flights[contentKey]?.consumers.count ?? 0
    }
    #endif
}
