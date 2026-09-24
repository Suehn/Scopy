import Foundation

enum MathEnvironmentSupport {
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

    static func environmentBeginName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\begin{") else { return nil }
        guard let close = trimmed.firstIndex(of: "}") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: "\\begin{".count)
        let name = String(trimmed[start..<close])
        return supportedEnvironmentNames.contains(name) ? name : nil
    }
}
