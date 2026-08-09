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
            let suffix = context.occurrenceCountIsTruncated ? "+" : ""
            append("\(context.occurrenceCount)\(suffix) 处 · ", to: &result)
        }
        if context.isPositionOnly {
            append("位置命中 · ", to: &result)
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
        let countSuffix = context.occurrenceCountIsTruncated ? "处以上命中" : "处命中"
        var parts = [
            "\(modeLabel(context.mode))搜索",
            "\(context.occurrenceCount)\(countSuffix)"
        ]

        if context.isPositionOnly {
            parts.append("位置命中")
        }

        let hasMultipleFragments = context.fragments.count > 1
        for (index, fragment) in context.fragments.enumerated() {
            let source = sourceLabel(
                for: fragment.source,
                itemType: itemType,
                alwaysShowContent: true
            ) ?? "正文"
            let fragmentLabel = hasMultipleFragments
                ? "片段\(index + 1)，\(source)"
                : source
            let highlights = highlightedStrings(in: fragment)
            if highlights.isEmpty {
                parts.append("\(fragmentLabel)：\(fragment.text)")
            } else {
                let visible = highlights.prefix(4).joined(separator: "、")
                let suffix = highlights.count > 4 ? "等" : ""
                parts.append(
                    "\(fragmentLabel)：\(fragment.text)；命中词：\(visible)\(suffix)"
                )
            }
        }

        return parts.joined(separator: "。") + "。"
    }

    private static func sourceLabel(
        for source: SearchMatchSource,
        itemType: ClipboardItemType,
        alwaysShowContent: Bool
    ) -> String? {
        switch source {
        case .note:
            return "备注"
        case .content where itemType == .file:
            return "路径"
        case .content where itemType == .image:
            return "图片"
        case .content where alwaysShowContent:
            return "正文"
        case .content:
            return nil
        }
    }

    private static func append(_ text: String, to result: inout AttributedString) {
        result.append(AttributedString(text))
    }

    private static func append(
        fragment: SearchMatchFragment,
        to result: inout AttributedString
    ) {
        let characters = Array(fragment.text)
        var cursor = 0
        for range in fragment.highlightedRanges {
            if cursor < range.offset {
                result.append(AttributedString(String(characters[cursor..<range.offset])))
            }

            let end = range.offset + range.length
            var highlighted = AttributedString(String(characters[range.offset..<end]))
            highlighted.backgroundColor = ScopyColors.searchMatch
            highlighted.foregroundColor = .black
            highlighted.inlinePresentationIntent = .stronglyEmphasized
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

    private static func modeLabel(_ mode: SearchMode) -> String {
        switch mode {
        case .exact:
            return "精确"
        case .fuzzy:
            return "模糊"
        case .fuzzyPlus:
            return "增强模糊"
        case .regex:
            return "正则"
        }
    }
}
