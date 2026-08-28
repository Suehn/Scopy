import Foundation

enum MarkdownRenderCacheKey {
    static func make(contentHash: String, context: MarkdownRenderContext) -> String {
        guard !contentHash.isEmpty else { return "" }
        return [
            "md",
            MarkdownRenderContextResolver.rendererVersion,
            context.profile.rawValue,
            context.layoutScale.cacheKey,
            contentHash
        ].joined(separator: "|")
    }

    static func make(contentHash: String, markdown: String) -> String {
        let context = MarkdownRenderContextResolver.defaultContext(for: markdown)
        return make(contentHash: contentHash, context: context)
    }
}
