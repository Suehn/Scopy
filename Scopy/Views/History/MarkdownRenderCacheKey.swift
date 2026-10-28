import Foundation

enum MarkdownRenderCacheKey {
    /// The exact source digest and frozen context identify both the document and its metrics.
    static func make(input context: MarkdownRenderContext, contentKey: String) -> String {
        return [
            "md",
            MarkdownRenderContextResolver.rendererVersion,
            context.profile.rawValue,
            context.layoutScale.cacheKey,
            context.linkEnrichment?.fingerprint ?? "plain",
            contentKey
        ].joined(separator: "|")
    }
}
