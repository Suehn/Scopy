import Foundation
import ScopyKit

/// One frozen render input and its HTML. Identity is derived while the HTML is built, never
/// reconstructed from a store that may have changed before the document reaches its owner.
struct PreparedMarkdownDocument: Sendable {
    let source: String
    let context: MarkdownRenderContext
    let contentKey: String
    let renderKey: String
    let html: String

    private init(source: String, context: MarkdownRenderContext, contentKey: String, renderKey: String) {
        self.source = source
        self.context = context
        self.contentKey = contentKey
        self.renderKey = renderKey
        self.html = MarkdownHTMLDocumentBuilder.document(source: source, context: context)
    }

    static func prepare(
        source: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent,
        store: LinkEnrichmentStore = .shared,
        onRender: (@Sendable (Double) -> Void)? = nil
    ) async -> PreparedMarkdownDocument {
        await Self.runPreparation {
            let contentKey = LinkEnrichmentContentKey.make(for: source)
            let payload = await store.payload(forContentKey: contentKey)
            let context = MarkdownRenderContextResolver.defaultContext(
                for: source,
                layoutScale: layoutScale,
                linkEnrichment: payload
            )
            return cachedOrRender(source: source, context: context, contentKey: contentKey, onRender: onRender)
        }
    }

    /// A visible document keeps its frozen payload when the derived disk cache is pruned.
    /// Appearance and notifications explicitly refresh it; body evaluation is pure.
    func refreshed(
        layoutScale: MarkdownChatGPTLayoutScalePercent,
        store: LinkEnrichmentStore = .shared
    ) async -> PreparedMarkdownDocument {
        await Self.runPreparation {
            let payload = await store.payload(forContentKey: contentKey) ?? context.linkEnrichment
            return replacingContext(layoutScale: layoutScale, linkEnrichment: payload)
        }
    }

    /// Export and scale changes can reuse this exact snapshot without consulting shared state.
    func withLayoutScale(_ layoutScale: MarkdownChatGPTLayoutScalePercent) async -> PreparedMarkdownDocument {
        guard context.layoutScale != layoutScale else { return self }
        return await Self.runPreparation {
            replacingContext(layoutScale: layoutScale, linkEnrichment: context.linkEnrichment)
        }
    }

    private func replacingContext(
        layoutScale: MarkdownChatGPTLayoutScalePercent,
        linkEnrichment: LinkEnrichmentPayload?
    ) -> PreparedMarkdownDocument {
        if context.layoutScale == layoutScale,
           (context.linkEnrichment?.fingerprint ?? "plain") == (linkEnrichment?.fingerprint ?? "plain") {
            return self
        }
        let updated = MarkdownRenderContext(
            profile: context.profile,
            policy: context.policy,
            layoutScale: layoutScale,
            linkEnrichment: linkEnrichment
        )
        return Self.cachedOrRender(source: source, context: updated, contentKey: contentKey)
    }

    private static func cachedOrRender(
        source: String,
        context: MarkdownRenderContext,
        contentKey: String,
        onRender: (@Sendable (Double) -> Void)? = nil
    ) -> PreparedMarkdownDocument {
        let renderKey = MarkdownRenderCacheKey.make(input: context, contentKey: contentKey)
        if let cached = MarkdownPreviewCache.shared.document(forKey: renderKey) { return cached }
        let startedAt = onRender == nil ? nil : CFAbsoluteTimeGetCurrent()
        let document = PreparedMarkdownDocument(
            source: source,
            context: context,
            contentKey: contentKey,
            renderKey: renderKey
        )
        if let startedAt { onRender?((CFAbsoluteTimeGetCurrent() - startedAt) * 1000) }
        MarkdownPreviewCache.shared.setDocument(document)
        return document
    }

    private static func runPreparation(
        _ operation: @escaping @Sendable () async -> PreparedMarkdownDocument
    ) async -> PreparedMarkdownDocument {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
