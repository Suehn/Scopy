import Foundation

struct MarkdownRenderFeatureSet: Equatable {
    let html: Bool
    let linkify: Bool
    let typographer: Bool
    let breaks: Bool
    let tables: Bool
    let strikethrough: Bool
    let taskLists: Bool
    let footnotes: Bool
    let definitionLists: Bool
    let safeHTMLSubset: Bool
    let codeHighlighting: Bool
    let math: Bool

    static let scopyDefault = Self(
        html: false,
        linkify: true,
        typographer: true,
        breaks: true,
        tables: true,
        strikethrough: true,
        taskLists: true,
        footnotes: true,
        definitionLists: true,
        safeHTMLSubset: true,
        codeHighlighting: true,
        math: true
    )

    var markdownAssetHeadTags: String {
        var tags = ["<script defer src=\"contrib/markdown-it.min.js\"></script>"]
        if footnotes {
            tags.append("<script defer src=\"contrib/markdown-it-footnote.js\"></script>")
        }
        if definitionLists {
            tags.append("<script defer src=\"contrib/markdown-it-deflist.js\"></script>")
        }
        if codeHighlighting {
            tags.append("<script defer src=\"contrib/highlight.min.js\"></script>")
            tags.append("<link rel=\"stylesheet\" href=\"contrib/highlight-github.min.css\">")
        }
        return tags.joined(separator: "\n        ")
    }

    var markdownItOptionsJSLiteral: String {
        "{ html: \(jsBool(html)), linkify: \(jsBool(linkify)), typographer: \(jsBool(typographer)), breaks: \(jsBool(breaks)) }"
    }

    var markdownItEnableStatementsJS: String {
        var statements: [String] = []
        if tables {
            statements.append("md.enable('table');")
        }
        if strikethrough {
            statements.append("md.enable('strikethrough');")
        }
        return statements.joined(separator: "\n                ")
    }

    var overflowProbeSelector: String {
        [
            "pre",
            "table",
            ".katex-display",
            ".footnotes",
            "details"
        ].joined(separator: ", ")
    }

    private func jsBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}
