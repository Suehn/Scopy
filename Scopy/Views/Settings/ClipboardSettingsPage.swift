import SwiftUI
import ScopyKit

struct ClipboardSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .clipboard) {
            SettingsSection(
                "内容类型",
                systemImage: "doc.on.clipboard",
                footer: "关闭某类内容后，Scopy 将跳过写入历史（不会影响当前剪贴板）。"
            ) {
                SettingsCardRow {
                    Toggle("保存图片", isOn: $tempSettings.saveImages)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Toggle("保存文件", isOn: $tempSettings.saveFiles)
                }
            }

            SettingsSection(
                "采样频率",
                systemImage: "timer",
                footer: "采样间隔越小，捕获越及时，但更耗电。"
            ) {
                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("剪贴板采样间隔")
                            Spacer()
                            Text("\(tempSettings.clipboardPollingIntervalMs) ms")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.clipboardPollingIntervalMs) },
                                set: { newValue in
                                    let stepped = (newValue / 100.0).rounded() * 100.0
                                    tempSettings.clipboardPollingIntervalMs = Int(stepped)
                                }
                            ),
                            in: 100...2000,
                            step: 100
                        )
                    }
                }
            }
        }
    }
}
