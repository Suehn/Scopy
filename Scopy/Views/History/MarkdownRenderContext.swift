import Foundation
import ScopyKit

enum MarkdownSourceProfile: String, Equatable, Sendable {
    case authoredMarkdown
    case chatGPTMarkdown
    case scientificMarkdown
    case latexDocumentLike
    case pdfOCRScientific
    case richHTML
    case plainTextUnknown
}

struct MarkdownRepairPolicy: Equatable, Sendable {
    let allowLatexDocumentNormalize: Bool
    let allowLatexInlineTextNormalize: Bool
    let allowLooseMathRepair: Bool

    static func conservativeDefault(for profile: MarkdownSourceProfile) -> MarkdownRepairPolicy {
        switch profile {
        case .latexDocumentLike, .pdfOCRScientific:
            return MarkdownRepairPolicy(
                allowLatexDocumentNormalize: true,
                allowLatexInlineTextNormalize: true,
                allowLooseMathRepair: true
            )
        case .scientificMarkdown:
            return MarkdownRepairPolicy(
                allowLatexDocumentNormalize: false,
                allowLatexInlineTextNormalize: true,
                allowLooseMathRepair: false
            )
        case .authoredMarkdown, .chatGPTMarkdown, .richHTML, .plainTextUnknown:
            return MarkdownRepairPolicy(
                allowLatexDocumentNormalize: false,
                allowLatexInlineTextNormalize: false,
                allowLooseMathRepair: false
            )
        }
    }
}

struct MarkdownRenderContext: Equatable, Sendable {
    let profile: MarkdownSourceProfile
    let policy: MarkdownRepairPolicy
    let layoutScale: MarkdownChatGPTLayoutScalePercent
    /// Frozen link-enrichment sidecar for this exact markdown content, when one exists.
    /// The enrichment setting gates fetching only; rendering always consumes whatever
    /// frozen payload is already stored so preview and export stay deterministic.
    var linkEnrichment: LinkEnrichmentPayload? = nil
}

enum MarkdownRenderContextResolver {
    static let rendererVersion = "chatgpt-renderer-v8"

    static func defaultContext(for markdown: String) -> MarkdownRenderContext {
        defaultContext(
            for: markdown,
            layoutScale: MarkdownRenderLayoutConstants.defaultChatGPTLayoutScale
        )
    }

    static func defaultContext(
        for markdown: String,
        layoutScale: MarkdownChatGPTLayoutScalePercent
    ) -> MarkdownRenderContext {
        let profile = MarkdownSourceProfileDetector.detect(markdown)
        return MarkdownRenderContext(
            profile: profile,
            policy: MarkdownRepairPolicy.conservativeDefault(for: profile),
            layoutScale: layoutScale,
            linkEnrichment: LinkEnrichmentStore.shared.payload(
                forContentKey: LinkEnrichmentContentKey.make(for: markdown)
            )
        )
    }
}
