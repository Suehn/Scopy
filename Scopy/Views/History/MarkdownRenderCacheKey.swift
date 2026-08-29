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
}
