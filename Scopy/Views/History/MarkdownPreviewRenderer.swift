import Foundation

protocol MarkdownPreviewRenderer {
    static var kind: MarkdownRendererKind { get }
    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput
}

struct MarkdownRenderOutput: Equatable {
    let html: String
    let diagnostics: MarkdownRenderDiagnostics
}

struct MarkdownRenderDiagnostics: Equatable {
    let renderer: MarkdownRendererKind
    let profile: MarkdownSourceProfile
    let policyVersion: String
    let protectedIslandCount: Int
    let explicitMathCount: Int
    let repairedMathCount: Int
    let fallbackReason: String?
    let warnings: [String]

    static func legacy(
        context: MarkdownRenderContext,
        protectedIslandCount: Int,
        explicitMathCount: Int,
        repairedMathCount: Int = 0,
        fallbackReason: String? = nil,
        warnings: [String] = []
    ) -> MarkdownRenderDiagnostics {
        MarkdownRenderDiagnostics(
            renderer: .legacyMarkdownIt,
            profile: context.profile,
            policyVersion: context.policyVersion,
            protectedIslandCount: protectedIslandCount,
            explicitMathCount: explicitMathCount,
            repairedMathCount: repairedMathCount,
            fallbackReason: fallbackReason,
            warnings: warnings
        )
    }
}
