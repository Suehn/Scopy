import Foundation

struct MarkdownRenderOutput: Equatable {
    let html: String
    let diagnostics: MarkdownRenderDiagnostics
}

struct MarkdownRenderDiagnostics: Equatable {
    let profile: MarkdownSourceProfile
    let explicitMathDetected: Bool
    let warnings: [String]
}
