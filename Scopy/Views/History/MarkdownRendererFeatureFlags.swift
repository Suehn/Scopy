import Foundation

struct MarkdownRendererFlagSet: Equatable {
    let forceLegacy: Bool
    let forceUnified: Bool
    let unifiedSafeProfilesEnabled: Bool
    let unifiedScientificEnabled: Bool
    let shadowUnifiedEnabled: Bool

    static let disabled = MarkdownRendererFlagSet(
        forceLegacy: false,
        forceUnified: false,
        unifiedSafeProfilesEnabled: false,
        unifiedScientificEnabled: false,
        shadowUnifiedEnabled: false
    )
}

enum MarkdownRendererFeatureFlags {
    static var current: MarkdownRendererFlagSet {
        let environment = ProcessInfo.processInfo.environment
        let rendererMode = environment["SCOPY_MARKDOWN_RENDERER"]?.lowercased() ?? ""
        return MarkdownRendererFlagSet(
            forceLegacy: rendererMode == "legacy",
            forceUnified: rendererMode == "unified",
            unifiedSafeProfilesEnabled: isEnabled(environment["SCOPY_MARKDOWN_UNIFIED_SAFE_PROFILES"]) || rendererMode == "safe",
            unifiedScientificEnabled: isEnabled(environment["SCOPY_MARKDOWN_UNIFIED_SCIENTIFIC"]),
            shadowUnifiedEnabled: isEnabled(environment["SCOPY_MARKDOWN_UNIFIED_SHADOW"])
        )
    }

    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }
}

enum MarkdownRendererSelector {
    static func rendererKind(
        for profile: MarkdownSourceProfile,
        flags: MarkdownRendererFlagSet = MarkdownRendererFeatureFlags.current
    ) -> MarkdownRendererKind {
        if flags.forceLegacy { return .legacyMarkdownIt }
        if flags.forceUnified { return .unified }

        switch profile {
        case .authoredMarkdown, .chatGPTMarkdown:
            return flags.unifiedSafeProfilesEnabled ? .unified : .legacyMarkdownIt
        case .scientificMarkdown:
            return flags.unifiedScientificEnabled ? .unified : .legacyMarkdownIt
        case .latexDocumentLike, .pdfOCRScientific, .richHTML, .plainTextUnknown:
            return .legacyMarkdownIt
        }
    }
}
