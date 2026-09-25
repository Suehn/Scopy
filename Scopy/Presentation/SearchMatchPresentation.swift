import SwiftUI
import ScopyKit

@MainActor
enum SearchMatchPresentation {
    static func attributedText(
        context: SearchMatchContext,
        itemType: ClipboardItemType,
        metadataPrefix: String?
    ) -> AttributedString {
        var result = AttributedString()

        if context.fragments.count == 1,
           context.fragments[0].source == .content,
           let metadataPrefix {
            append("\(metadataPrefix) · ", to: &result)
        }

        if context.occurrenceCount > 1 || context.occurrenceCountIsTruncated {
            let count = context.occurrenceCountIsTruncated
                ? String(localized: "\(context.occurrenceCount)+ matches")
                : String(localized: "\(context.occurrenceCount) matches")
            append("\(count) · ", to: &result)
        }
        if context.isPositionOnly {
            append("\(String(localized: "Position match")) · ", to: &result)
        }

        let hasMixedSources = Set(context.fragments.map(\.source)).count > 1
        for (index, fragment) in context.fragments.enumerated() {
            if index > 0 {
                append("  /  ", to: &result)
            }
            if let label = sourceLabel(
                for: fragment.source,
                itemType: itemType,
                alwaysShowContent: hasMixedSources
            ) {
                append("\(label) · ", to: &result)
            }
            append(fragment: fragment, to: &result)
        }

        return result
    }

    static func accessibilityDescription(
        context: SearchMatchContext,
        itemType: ClipboardItemType
    ) -> String {
        let count = context.occurrenceCountIsTruncated
            ? String(localized: "\(context.occurrenceCount) or more matches found")
            : String(localized: "\(context.occurrenceCount) matches found")
        var parts = [
            String(localized: "\(modeLabel(context.mode)) search"),
            count
        ]

        if context.isPositionOnly {
            parts.append(String(localized: "Position match"))
        }

        let hasMultipleFragments = context.fragments.count > 1
        for (index, fragment) in context.fragments.enumerated() {
            let source = sourceLabel(
                for: fragment.source,
                itemType: itemType,
                alwaysShowContent: true
            ) ?? String(localized: "Content")
            let fragmentLabel = hasMultipleFragments
                ? String(localized: "Fragment \(index + 1), \(source)")
                : source
            let text = displayText(for: fragment)
            let highlights = highlightedStrings(in: fragment)
            if highlights.isEmpty {
                parts.append(String(localized: "\(fragmentLabel): \(text)"))
            } else {
                let visible = ListFormatter.localizedString(byJoining: Array(highlights.prefix(4)))
                let matches = highlights.count > 4 ? String(localized: "\(visible) and more") : visible
                parts.append(String(localized: "\(fragmentLabel): \(text); matches: \(matches)"))
            }
        }

        return parts.map { String(localized: "\($0).") }.joined(separator: " ")
    }

    private static func sourceLabel(
        for source: SearchMatchSource,
        itemType: ClipboardItemType,
        alwaysShowContent: Bool
    ) -> String? {
        switch source {
        case .note:
            return String(localized: "Note")
        case .content where itemType == .file:
            return String(localized: "Path")
        case .content where itemType == .image:
            return String(localized: "Image")
        case .content where alwaysShowContent:
            return String(localized: "Content")
        case .content:
            return nil
        }
    }

    /// A fragment with no text matched content that has no visible characters.
    private static func displayText(for fragment: SearchMatchFragment) -> String {
        fragment.text.isEmpty ? String(localized: "(Blank content)") : fragment.text
    }

    private static func append(_ text: String, to result: inout AttributedString) {
        result.append(AttributedString(text))
    }

    private static func append(
        fragment: SearchMatchFragment,
        to result: inout AttributedString
    ) {
        let characters = Array(displayText(for: fragment))
        var cursor = 0
        for range in fragment.highlightedRanges {
            if cursor < range.offset {
                result.append(AttributedString(String(characters[cursor..<range.offset])))
            }

            let end = range.offset + range.length
            var highlighted = AttributedString(String(characters[range.offset..<end]))
            highlighted[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = ScopyColors.searchMatch
            highlighted[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .black
            highlighted[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .stronglyEmphasized
            result.append(highlighted)
            cursor = end
        }
        if cursor < characters.count {
            result.append(AttributedString(String(characters[cursor...])))
        }
    }

    private static func highlightedStrings(in fragment: SearchMatchFragment) -> [String] {
        let characters = Array(fragment.text)
        return fragment.highlightedRanges.compactMap { range in
            let end = range.offset + range.length
            guard range.offset >= 0,
                  range.length > 0,
                  end <= characters.count else { return nil }
            return String(characters[range.offset..<end])
        }
    }

    /// Search modes are product terms and stay untranslated, as in the header menu.
    private static func modeLabel(_ mode: SearchMode) -> String {
        switch mode {
        case .exact:
            return "Exact"
        case .fuzzy:
            return "Fuzzy"
        case .fuzzyPlus:
            return "Fuzzy+"
        case .regex:
            return "Regex"
        }
    }
}
