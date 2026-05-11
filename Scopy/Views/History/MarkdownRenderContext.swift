import Foundation

enum MarkdownRendererKind: String, Equatable {
    case legacyMarkdownIt
    case unified
}

enum MarkdownSourceProfile: String, Equatable {
    case authoredMarkdown
    case chatGPTMarkdown
    case scientificMarkdown
    case latexDocumentLike
    case pdfOCRScientific
    case richHTML
    case plainTextUnknown
}

struct MarkdownRepairPolicy: Equatable {
    let allowLatexDocumentNormalize: Bool
    let allowLatexInlineTextNormalize: Bool
    let allowExplicitMath: Bool
    let allowBackslashMath: Bool
    let allowLooseMathRepair: Bool
    let allowSafeHTMLSubset: Bool
    let allowRawHTML: Bool

    static func legacyCompatible(for profile: MarkdownSourceProfile) -> MarkdownRepairPolicy {
        MarkdownRepairPolicy(
            allowLatexDocumentNormalize: true,
            allowLatexInlineTextNormalize: true,
            allowExplicitMath: true,
            allowBackslashMath: true,
            allowLooseMathRepair: true,
            allowSafeHTMLSubset: true,
            allowRawHTML: false
        )
    }

    static func conservativeDefault(for profile: MarkdownSourceProfile) -> MarkdownRepairPolicy {
        switch profile {
        case .latexDocumentLike, .pdfOCRScientific:
            return MarkdownRepairPolicy(
                allowLatexDocumentNormalize: true,
                allowLatexInlineTextNormalize: true,
                allowExplicitMath: true,
                allowBackslashMath: true,
                allowLooseMathRepair: true,
                allowSafeHTMLSubset: true,
                allowRawHTML: false
            )
        case .scientificMarkdown:
            return MarkdownRepairPolicy(
                allowLatexDocumentNormalize: false,
                allowLatexInlineTextNormalize: true,
                allowExplicitMath: true,
                allowBackslashMath: true,
                allowLooseMathRepair: false,
                allowSafeHTMLSubset: true,
                allowRawHTML: false
            )
        case .authoredMarkdown, .chatGPTMarkdown, .richHTML, .plainTextUnknown:
            return MarkdownRepairPolicy(
                allowLatexDocumentNormalize: false,
                allowLatexInlineTextNormalize: false,
                allowExplicitMath: true,
                allowBackslashMath: true,
                allowLooseMathRepair: false,
                allowSafeHTMLSubset: true,
                allowRawHTML: false
            )
        }
    }
}

struct MarkdownRenderContext: Equatable {
    let renderer: MarkdownRendererKind
    let profile: MarkdownSourceProfile
    let policy: MarkdownRepairPolicy
    let policyVersion: String
    let cacheNamespace: String

    func withRenderer(_ renderer: MarkdownRendererKind) -> MarkdownRenderContext {
        MarkdownRenderContext(
            renderer: renderer,
            profile: profile,
            policy: policy,
            policyVersion: policyVersion,
            cacheNamespace: cacheNamespace
        )
    }
}

enum MarkdownRenderContextResolver {
    static let legacyPolicyVersion = "legacy-policy-v1"
    static let legacyCacheNamespace = "legacy-markdown-it-v1"

    static func defaultContext(for markdown: String) -> MarkdownRenderContext {
        let profile = MarkdownSourceProfileDetector.detect(markdown)
        let renderer = MarkdownRendererSelector.rendererKind(for: profile)
        return MarkdownRenderContext(
            renderer: renderer,
            profile: profile,
            policy: MarkdownRepairPolicy.legacyCompatible(for: profile),
            policyVersion: legacyPolicyVersion,
            cacheNamespace: legacyCacheNamespace
        )
    }
}
