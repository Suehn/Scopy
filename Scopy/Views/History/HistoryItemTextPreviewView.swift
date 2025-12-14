import SwiftUI
import ScopyKit

struct HistoryItemTextPreviewView: View {
    @ObservedObject var model: HoverPreviewModel

    var body: some View {
        Group {
            if let text = model.text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(ScopySpacing.md)
                        .padding(.bottom, ScopySpacing.md)  // 额外底部 padding 防止截断
                }
            } else {
                ProgressView()
                    .padding(ScopySpacing.md)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 400)
    }
}
