import AppKit
import CoreGraphics
import Foundation

enum HoverPreviewTextSizing {
    static func preferredWidth(
        for text: String,
        font: NSFont,
        padding: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        if text.isEmpty { return max(1, maxWidth) }

        // Avoid sizing work for large payloads.
        if text.utf16.count >= 1_500 { return maxWidth }

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.isEmpty { return max(1, maxWidth) }

        // Prefer shrinking for small payloads (including short multi-line outputs), but keep max width
        // for very large/many-line content to avoid excessive layout work and unstable reflow.
        if lines.count > 80 { return maxWidth }

        let maxMeasuredLineWidth: CGFloat = lines.prefix(80).reduce(0) { acc, line in
            let s = String(line).replacingOccurrences(of: "\t", with: "    ")
            let measured = (s as NSString).size(withAttributes: [.font: font])
            return max(acc, measured.width)
        }

        // Add some slack so glyph descenders/emoji don't get clipped on edge cases.
        let desired = maxMeasuredLineWidth + padding * 2 + 8

        // If the content is close to max width, just use max width to keep layout stable.
        if desired >= maxWidth * 0.92 { return maxWidth }

        return max(1, min(maxWidth, ceil(desired)))
    }

    static func preferredTextHeight(
        for text: String,
        font: NSFont,
        contentWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        guard contentWidth > 0 else { return 0 }
        if text.isEmpty { return 0 }

        // Avoid heavy measurement for very large strings; long content can just use max height + scroll.
        if text.utf16.count >= 1_500 { return maxHeight }

        let measured = measureText(text, font: font, contentWidth: contentWidth)
        return min(maxHeight, measured.height)
    }

    // MARK: - Text Kit measurement

    private static func measureText(_ text: String, font: NSFont, contentWidth: CGFloat) -> CGSize {
        // TextKit-based measurement matches NSTextView layout far more closely than `boundingRect`.
        let textStorage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        _ = layoutManager.glyphRange(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}
