import SwiftUI
import ScopyKit

struct AppearanceSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .appearance) {
            SettingsSection(
                "预览",
                systemImage: "photo",
                footer: "开启缩略图可提升列表可读性；悬停可预览原图（延迟用于避免误触）。"
            ) {
                SettingsCardRow {
                    Toggle("显示图片缩略图", isOn: $tempSettings.showImageThumbnails)
                }

                if tempSettings.showImageThumbnails {
                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("缩略图高度") {
                            Picker("", selection: $tempSettings.thumbnailHeight) {
                                Text("30 px").tag(30)
                                Text("40 px").tag(40)
                                Text("50 px").tag(50)
                                Text("60 px").tag(60)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: ScopySize.Width.pickerMenu)
                        }
                    }

                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("悬停预览延迟") {
                            Picker("", selection: $tempSettings.imagePreviewDelay) {
                                Text("0.5 秒").tag(0.5)
                                Text("1.0 秒").tag(1.0)
                                Text("1.5 秒").tag(1.5)
                                Text("2.0 秒").tag(2.0)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: ScopySize.Width.pickerMenu)
                        }
                    }
                }
            }

            SettingsSection(
                "Markdown",
                systemImage: "doc.richtext",
                footer: "渲染比例只影响 Markdown 预览和 PNG 导出的字体度量与换行；导出图片宽度仍保持固定。"
            ) {
                SettingsCardRow {
                    LabeledContent("ChatGPT 页面比例") {
                        HStack(spacing: ScopySpacing.sm) {
                            Text(MarkdownChatGPTLayoutScalePercent(settingsValue: tempSettings.markdownChatGPTLayoutScalePercent).label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ScopyColors.mutedText)
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)

                            Slider(
                                value: markdownLayoutScaleBinding,
                                in: Double(MarkdownChatGPTLayoutScalePercent.minimumRawValue)...Double(MarkdownChatGPTLayoutScalePercent.maximumRawValue)
                            )
                            .frame(width: 170)
                            .accessibilityIdentifier("Settings.MarkdownLayoutScaleSlider")
                            .accessibilityLabel("Markdown ChatGPT layout scale")
                            .accessibilityValue(MarkdownChatGPTLayoutScalePercent(settingsValue: tempSettings.markdownChatGPTLayoutScalePercent).label)
                        }
                    }
                }
            }
        }
    }

    private var markdownLayoutScaleBinding: Binding<Double> {
        Binding(
            get: {
                Double(MarkdownChatGPTLayoutScalePercent(settingsValue: tempSettings.markdownChatGPTLayoutScalePercent).rawValue)
            },
            set: { value in
                tempSettings.markdownChatGPTLayoutScalePercent = MarkdownChatGPTLayoutScalePercent
                    .magneticValue(from: value)
            }
        )
    }
}
