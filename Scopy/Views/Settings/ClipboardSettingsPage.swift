import SwiftUI
import ScopyKit

struct ClipboardSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .clipboard) {
            Section {
                Toggle("保存图片", isOn: $tempSettings.saveImages)
                Toggle("保存文件", isOn: $tempSettings.saveFiles)
            } header: {
                Label("内容类型", systemImage: "doc.on.clipboard")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("关闭某类内容后，Scopy 将跳过写入历史（不会影响当前剪贴板）。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
