import Foundation

/// Loading Markdown has source text but no document identity yet. A prepared document owns
/// its source and context together, so presentation cannot pair HTML with a newer sidecar.
enum HoverPreviewTextContent: Sendable {
    case plain(String)
    case markdownSource(String?)
    case markdown(PreparedMarkdownDocument)

    var text: String? {
        switch self {
        case .plain(let text), .markdownSource(let text?): return text
        case .markdown(let document): return document.source
        case .markdownSource(nil): return nil
        }
    }

    var isMarkdown: Bool {
        switch self {
        case .plain: return false
        case .markdownSource, .markdown: return true
        }
    }

    var document: PreparedMarkdownDocument? {
        if case .markdown(let document) = self { return document }
        return nil
    }
}
