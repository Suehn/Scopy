import SwiftUI

struct HistoryItemTextPreviewView: View {
    let text: String?

    var body: some View {
        ScrollView {
            Text(text ?? "(Empty)")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ScopySpacing.md)
                .padding(.bottom, ScopySpacing.md)  // 额外底部 padding 防止截断
        }
        .frame(width: 400)
        .frame(maxHeight: 400)
    }
}

