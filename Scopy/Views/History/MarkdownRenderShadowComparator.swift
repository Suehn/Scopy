import Foundation
import ScopyUISupport

struct MarkdownRenderShadowSignals: Equatable {
    let htmlIsEmpty: Bool
    let linkCount: Int
    let codeBlockCount: Int
    let tableCount: Int
    let footnoteMarkerCount: Int
    let mathCount: Int
    let externalAssetReferenceCount: Int
}

struct MarkdownRenderShadowReport: Equatable {
    let profile: MarkdownSourceProfile
    let primaryRenderer: MarkdownRendererKind
    let shadowRenderer: MarkdownRendererKind
    let primary: MarkdownRenderShadowSignals
    let shadow: MarkdownRenderShadowSignals
    let warnings: [String]

    var hasMismatch: Bool {
        !warnings.isEmpty
    }
}

enum MarkdownRenderShadowComparator {
    static func shouldShadow(context: MarkdownRenderContext, flags: MarkdownRendererFlagSet) -> Bool {
        flags.shadowUnifiedEnabled &&
            context.renderer == .legacyMarkdownIt &&
            context.profile.isSafeForUnifiedShadow
    }

    @discardableResult
    static func record(
        primary: MarkdownRenderOutput,
        shadow: MarkdownRenderOutput,
        source: String,
        context: MarkdownRenderContext,
        shadowRenderMs: Double? = nil
    ) -> MarkdownRenderShadowReport {
        if let shadowRenderMs {
            ScrollPerformanceProfile.recordMetric(
                name: "markdown.shadow_unified_render_ms",
                elapsedMs: shadowRenderMs
            )
        }
        return compare(primary: primary, shadow: shadow, source: source, context: context)
    }

    static func compare(
        primary: MarkdownRenderOutput,
        shadow: MarkdownRenderOutput,
        source _: String,
        context: MarkdownRenderContext
    ) -> MarkdownRenderShadowReport {
        let primarySignals = signals(for: primary)
        let shadowSignals = signals(for: shadow)
        var warnings: [String] = []

        if primarySignals.htmlIsEmpty {
            warnings.append("primary html is empty")
        }
        if shadowSignals.htmlIsEmpty {
            warnings.append("shadow html is empty")
        }
        appendCountWarnings(
            primary: primarySignals,
            shadow: shadowSignals,
            warnings: &warnings
        )
        if shadowSignals.externalAssetReferenceCount > 0 {
            warnings.append("shadow html references external assets")
        }
        if let fallbackReason = shadow.diagnostics.fallbackReason, !fallbackReason.isEmpty {
            warnings.append("shadow fallback: \(fallbackReason)")
        }

        return MarkdownRenderShadowReport(
            profile: context.profile,
            primaryRenderer: primary.diagnostics.renderer,
            shadowRenderer: shadow.diagnostics.renderer,
            primary: primarySignals,
            shadow: shadowSignals,
            warnings: warnings
        )
    }

    private static func signals(for output: MarkdownRenderOutput) -> MarkdownRenderShadowSignals {
        let html = output.html
        return MarkdownRenderShadowSignals(
            htmlIsEmpty: html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            linkCount: countTag("a", in: html),
            codeBlockCount: countTag("pre", in: html),
            tableCount: countTag("table", in: html),
            footnoteMarkerCount: countOccurrences(of: "footnote-ref", in: html) +
                countOccurrences(of: "footnote-backref", in: html),
            mathCount: max(
                output.diagnostics.explicitMathCount + output.diagnostics.repairedMathCount,
                countOccurrences(of: "katex", in: html)
            ),
            externalAssetReferenceCount: countExternalAssetReferences(in: html)
        )
    }

    private static func appendCountWarnings(
        primary: MarkdownRenderShadowSignals,
        shadow: MarkdownRenderShadowSignals,
        warnings: inout [String]
    ) {
        appendCountWarning(name: "link", primary: primary.linkCount, shadow: shadow.linkCount, warnings: &warnings)
        appendCountWarning(name: "code block", primary: primary.codeBlockCount, shadow: shadow.codeBlockCount, warnings: &warnings)
        appendCountWarning(name: "table", primary: primary.tableCount, shadow: shadow.tableCount, warnings: &warnings)
        appendCountWarning(name: "footnote marker", primary: primary.footnoteMarkerCount, shadow: shadow.footnoteMarkerCount, warnings: &warnings)
        appendCountWarning(name: "math", primary: primary.mathCount, shadow: shadow.mathCount, warnings: &warnings)
    }

    private static func appendCountWarning(
        name: String,
        primary: Int,
        shadow: Int,
        warnings: inout [String]
    ) {
        guard primary != shadow else { return }
        guard primary > 0 || shadow > 0 else { return }
        warnings.append("\(name) count differs: primary=\(primary), shadow=\(shadow)")
    }

    private static func countTag(_ tag: String, in html: String) -> Int {
        countMatches(pattern: #"<\s*\#(tag)(\s|>|/)"#, in: html)
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [.caseInsensitive], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func countExternalAssetReferences(in html: String) -> Int {
        countMatches(
            pattern: #"<\s*(script|link|img|iframe|source)\b[^>]*(src|href)\s*=\s*['"]https?://"#,
            in: html
        )
    }

    private static func countMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }
}

private extension MarkdownSourceProfile {
    var isSafeForUnifiedShadow: Bool {
        switch self {
        case .authoredMarkdown, .chatGPTMarkdown, .scientificMarkdown:
            return true
        case .latexDocumentLike, .pdfOCRScientific, .richHTML, .plainTextUnknown:
            return false
        }
    }
}
