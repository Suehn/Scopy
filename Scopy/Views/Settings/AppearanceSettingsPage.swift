import SwiftUI
import ScopyKit

struct AppearanceSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .appearance) {
            Section {
                Toggle("显示图片缩略图", isOn: $tempSettings.showImageThumbnails)

                if tempSettings.showImageThumbnails {
                    LabeledContent("缩略图高度") {
                        Picker("", selection: $tempSettings.thumbnailHeight) {
                            Text("30 px").tag(30)
                            Text("40 px").tag(40)
                            Text("50 px").tag(50)
                            Text("60 px").tag(60)
                        }
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                    }

                    LabeledContent("悬停预览延迟") {
                        Picker("", selection: $tempSettings.imagePreviewDelay) {
                            Text("0.5 秒").tag(0.5)
                            Text("1.0 秒").tag(1.0)
                            Text("1.5 秒").tag(1.5)
                            Text("2.0 秒").tag(2.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                    }
                }
            } header: {
                Label("预览", systemImage: "photo")
            } footer: {
                Text("开启缩略图可提升列表可读性；悬停可预览原图（延迟用于避免误触）。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

