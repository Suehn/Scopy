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

        // If it's clearly multi-line, keep the stable max width to avoid jitter as content reflows.
        if text.contains("\n") { return maxWidth }

        // Single-line: measure without a container. Using TextKit's `usedRect` tends to report the full
        // line fragment width, which prevents shrinking for short strings.
        let measured = (text as NSString).size(withAttributes: [.font: font])
        // Add some slack so glyph descenders/emoji don't get clipped on edge cases.
        let desired = measured.width + padding * 2 + 8
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

        var newlineCount = 0
        for ch in text {
            if ch == "\n" {
                newlineCount += 1
                if newlineCount >= 20 { return maxHeight }
            }
        }

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
