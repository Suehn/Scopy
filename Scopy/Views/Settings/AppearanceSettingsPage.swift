import SwiftUI
import ScopyKit

struct AppearanceSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .appearance) {
            SettingsSection(
                "Preview",
                systemImage: "photo",
                footer: "Thumbnails make the list easier to scan. Hover a row to preview the original; the delay avoids accidental previews."
            ) {
                SettingsCardRow {
                    Toggle("Show image thumbnails", isOn: $tempSettings.showImageThumbnails)
                }

                if tempSettings.showImageThumbnails {
                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("Thumbnail height") {
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
                        LabeledContent("Hover preview delay") {
                            Picker("", selection: $tempSettings.imagePreviewDelay) {
                                Text("0.5 s").tag(0.5)
                                Text("1.0 s").tag(1.0)
                                Text("1.5 s").tag(1.5)
                                Text("2.0 s").tag(2.0)
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
                footer: "The layout scale affects only font metrics and line wrapping in Markdown previews and PNG exports; the exported image width stays fixed. Link previews are off by default: when on, bare links in assistant content such as ChatGPT or Codex fetch a title and thumbnail over the network and are frozen locally as cards. Rendering and export always stay offline."
            ) {
                SettingsCardRow {
                    LabeledContent("ChatGPT layout scale") {
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

                SettingsCardDivider()

                SettingsCardRow {
                    Toggle("Website icons (fetched online and cached)", isOn: $tempSettings.siteIconsEnabled)
                        .accessibilityIdentifier("Settings.SiteIconsToggle")
                }

                SettingsCardRow {
                    Toggle("Link previews (online)", isOn: $tempSettings.linkEnrichmentEnabled)
                        .accessibilityIdentifier("Settings.LinkEnrichmentToggle")
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
