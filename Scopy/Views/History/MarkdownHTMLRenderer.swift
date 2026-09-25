import Foundation

enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        render(markdown: markdown, context: MarkdownRenderContextResolver.defaultContext(for: markdown))
    }

    /// Every source repair, including the scientific profiles' LaTeX normalization, runs in the
    /// renderer bundle; the source is embedded verbatim with the policy that gates those repairs.
    static func render(markdown: String, context: MarkdownRenderContext) -> String {
        MarkdownHTMLDocumentBuilder.document(markdown: markdown, context: context)
    }
}
