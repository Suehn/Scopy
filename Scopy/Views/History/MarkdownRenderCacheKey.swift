import Foundation

enum MarkdownRenderCacheKey {
    /// `itemKey` identifies the previewed item revision or file preview (not a content hash); `input` is the render
    /// context, whose renderer version, profile, layout scale and enrichment fingerprint all change the document.
    static func make(input context: MarkdownRenderContext, itemKey: String) -> String {
        guard !itemKey.isEmpty else { return "" }
        return [
            "md",
            MarkdownRenderContextResolver.rendererVersion,
            context.profile.rawValue,
            context.layoutScale.cacheKey,
            context.linkEnrichment?.fingerprint ?? "plain",
            itemKey
        ].joined(separator: "|")
    }
}
