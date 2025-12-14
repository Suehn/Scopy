import SwiftUI
import ScopyKit
import AppKit

struct HistoryItemTextPreviewView: View {
    @ObservedObject var model: HoverPreviewModel

    var body: some View {
        let maxWidth: CGFloat = 400
        let maxHeight: CGFloat = ScopySize.Window.mainHeight
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let padding: CGFloat = ScopySpacing.md
        let bottomExtraPadding: CGFloat = ScopySpacing.md

        Group {
            if let text = model.text {
                let contentHeight = measuredTextHeight(text, font: font, width: maxWidth - padding * 2)
                let desiredHeight = min(maxHeight, contentHeight + padding * 2 + bottomExtraPadding)
                let shouldScroll = desiredHeight >= maxHeight

                if shouldScroll {
                    ScrollView {
                        previewText(text)
                            .padding(padding)
                            .padding(.bottom, bottomExtraPadding)
                    }
                    .frame(width: maxWidth, height: maxHeight)
                } else {
                    previewText(text)
                        .padding(padding)
                        .padding(.bottom, bottomExtraPadding)
                        .frame(width: maxWidth, height: desiredHeight, alignment: .topLeading)
                }
            } else {
                ProgressView()
                    .padding(padding)
            }
        }
    }

    private func previewText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func measuredTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let rect = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
}
