import Foundation

enum MathEnvironmentSupport {
    struct Delimiter {
        let left: String
        let right: String
        let display: Bool
    }

    // Single source of truth for supported LaTeX environments in hover preview.
    static let supportedEnvironmentNamesInOrder: [String] = [
        "equation", "equation*",
        "align", "align*",
        "alignat", "alignat*",
        "alignedat",
        "aligned",
        "cases",
        "gather", "gather*",
        "multline", "multline*",
        "split",
        // Matrix / array-like environments commonly used in math snippets.
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "array"
    ]
    static let supportedEnvironmentNames: Set<String> = Set(supportedEnvironmentNamesInOrder)

    static let katexAutoRenderDelimiters: [Delimiter] = [
        // Environment-style display math.
        .init(left: "\\begin{equation}", right: "\\end{equation}", display: true),
        .init(left: "\\begin{equation*}", right: "\\end{equation*}", display: true),
        .init(left: "\\begin{align}", right: "\\end{align}", display: true),
        .init(left: "\\begin{align*}", right: "\\end{align*}", display: true),
        .init(left: "\\begin{alignat}", right: "\\end{alignat}", display: true),
        .init(left: "\\begin{alignat*}", right: "\\end{alignat*}", display: true),
        .init(left: "\\begin{alignedat}", right: "\\end{alignedat}", display: true),
        .init(left: "\\begin{aligned}", right: "\\end{aligned}", display: true),
        .init(left: "\\begin{cases}", right: "\\end{cases}", display: true),
        .init(left: "\\begin{gather}", right: "\\end{gather}", display: true),
        .init(left: "\\begin{gather*}", right: "\\end{gather*}", display: true),
        .init(left: "\\begin{multline}", right: "\\end{multline}", display: true),
        .init(left: "\\begin{multline*}", right: "\\end{multline*}", display: true),
        .init(left: "\\begin{split}", right: "\\end{split}", display: true),
        .init(left: "\\begin{matrix}", right: "\\end{matrix}", display: true),
        .init(left: "\\begin{pmatrix}", right: "\\end{pmatrix}", display: true),
        .init(left: "\\begin{bmatrix}", right: "\\end{bmatrix}", display: true),
        .init(left: "\\begin{Bmatrix}", right: "\\end{Bmatrix}", display: true),
        .init(left: "\\begin{vmatrix}", right: "\\end{vmatrix}", display: true),
        .init(left: "\\begin{Vmatrix}", right: "\\end{Vmatrix}", display: true),
        .init(left: "\\begin{smallmatrix}", right: "\\end{smallmatrix}", display: true),
        .init(left: "\\begin{array}", right: "\\end{array}", display: true),
        // Dollar and bracket delimiters.
        .init(left: "$$", right: "$$", display: true),
        .init(left: "$", right: "$", display: false),
        .init(left: "\\[", right: "\\]", display: true),
        .init(left: "\\(", right: "\\)", display: false)
    ]

    static func environmentBeginName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\begin{") else { return nil }
        guard let close = trimmed.firstIndex(of: "}") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: "\\begin{".count)
        let name = String(trimmed[start..<close])
        return supportedEnvironmentNames.contains(name) ? name : nil
    }

    static func katexDelimitersJSArrayLiteral() -> String {
        // Render to a JS array literal: [{left: '...', right: '...', display: true}, ...]
        let items = katexAutoRenderDelimiters.map { d in
            let left = escapeForJSSingleQuotedString(d.left)
            let right = escapeForJSSingleQuotedString(d.right)
            let display = d.display ? "true" : "false"
            return "{left: '\(left)', right: '\(right)', display: \(display)}"
        }
        return "[\n  " + items.joined(separator: ",\n  ") + "\n]"
    }

    private static func escapeForJSSingleQuotedString(_ s: String) -> String {
        // Escape for JS single-quoted literals embedded in an inline <script>.
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "'", with: "\\'")
        out = out.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
        return out
    }
}
