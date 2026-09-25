import SwiftUI
import ScopyKit

struct ClipboardSettingsPage: View {
    @Binding var tempSettings: SettingsDTO

    var body: some View {
        SettingsPageContainer(page: .clipboard) {
            SettingsSection(
                "Content types",
                systemImage: "doc.on.clipboard",
                footer: "When a content type is off, Scopy does not add it to history. The current clipboard is not affected."
            ) {
                SettingsCardRow {
                    Toggle("Save images", isOn: $tempSettings.saveImages)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Toggle("Save files", isOn: $tempSettings.saveFiles)
                }
            }

            SettingsSection(
                "Image optimization (pngquant)",
                systemImage: "photo",
                footer: "pngquant is bundled with Scopy. Click the optimize button on an image row to compress that image in place, or compress new images automatically before they are saved to history. Both use the same parameters."
            ) {
                SettingsCardRow {
                    Toggle("Compress new images automatically", isOn: $tempSettings.pngquantCopyImageEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Quality range")
                            Spacer()
                            Text("\(tempSettings.pngquantCopyImageQualityMin)-\(tempSettings.pngquantCopyImageQualityMax)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.pngquantCopyImageQualityMin) },
                                set: { newValue in
                                    let value = Int(newValue.rounded())
                                    tempSettings.pngquantCopyImageQualityMin = max(0, min(100, value))
                                    if tempSettings.pngquantCopyImageQualityMin > tempSettings.pngquantCopyImageQualityMax {
                                        tempSettings.pngquantCopyImageQualityMax = tempSettings.pngquantCopyImageQualityMin
                                    }
                                }
                            ),
                            in: 0...100,
                            step: 1
                        )

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.pngquantCopyImageQualityMax) },
                                set: { newValue in
                                    let value = Int(newValue.rounded())
                                    tempSettings.pngquantCopyImageQualityMax = max(0, min(100, value))
                                    if tempSettings.pngquantCopyImageQualityMax < tempSettings.pngquantCopyImageQualityMin {
                                        tempSettings.pngquantCopyImageQualityMin = tempSettings.pngquantCopyImageQualityMax
                                    }
                                }
                            ),
                            in: 0...100,
                            step: 1
                        )
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(tempSettings.pngquantCopyImageSpeed)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.pngquantCopyImageSpeed) },
                                set: { newValue in
                                    let stepped = newValue.rounded()
                                    tempSettings.pngquantCopyImageSpeed = Int(max(1, min(11, stepped)))
                                }
                            ),
                            in: 1...11,
                            step: 1
                        )
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    LabeledContent("Colors") {
                        Picker("", selection: $tempSettings.pngquantCopyImageColors) {
                            Text("16").tag(16)
                            Text("32").tag(32)
                            Text("64").tag(64)
                            Text("128").tag(128)
                            Text("256").tag(256)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                    }
                }
            }

            SettingsSection(
                "PNG export compression (pngquant)",
                systemImage: "square.and.arrow.up",
                footer: "When on, a Markdown or LaTeX PNG export to the clipboard is compressed with pngquant first and only the compressed PNG is copied (it enters history). On by default."
            ) {
                SettingsCardRow {
                    Toggle("Compress exported PNG", isOn: $tempSettings.pngquantMarkdownExportEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Quality range")
                            Spacer()
                            Text("\(tempSettings.pngquantMarkdownExportQualityMin)-\(tempSettings.pngquantMarkdownExportQualityMax)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.pngquantMarkdownExportQualityMin) },
                                set: { newValue in
                                    let value = Int(newValue.rounded())
                                    tempSettings.pngquantMarkdownExportQualityMin = max(0, min(100, value))
                                    if tempSettings.pngquantMarkdownExportQualityMin > tempSettings.pngquantMarkdownExportQualityMax {
                                        tempSettings.pngquantMarkdownExportQualityMax = tempSettings.pngquantMarkdownExportQualityMin
                                    }
                                }
                            ),
                            in: 0...100,
                            step: 1
                        )

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.pngquantMarkdownExportQualityMax) },
                                set: { newValue in
                                    let value = Int(newValue.rounded())
                                    tempSettings.pngquantMarkdownExportQualityMax = max(0, min(100, value))
                                    if tempSettings.pngquantMarkdownExportQualityMax < tempSettings.pngquantMarkdownExportQualityMin {
                                        tempSettings.pngquantMarkdownExportQualityMin = tempSettings.pngquantMarkdownExportQualityMax
                                    }
                                }
                            ),
                            in: 0...100,
                            step: 1
                        )
                    }
                    .disabled(!tempSettings.pngquantMarkdownExportEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(tempSettings.pngquantMarkdownExportSpeed)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(tempSettings.pngquantMarkdownExportSpeed) },
                                set: { newValue in
                                    let stepped = newValue.rounded()
                                    tempSettings.pngquantMarkdownExportSpeed = Int(max(1, min(11, stepped)))
                                }
                            ),
                            in: 1...11,
                            step: 1
                        )
                    }
                    .disabled(!tempSettings.pngquantMarkdownExportEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    LabeledContent("Colors") {
                        Picker("", selection: $tempSettings.pngquantMarkdownExportColors) {
                            Text("16").tag(16)
                            Text("32").tag(32)
                            Text("64").tag(64)
                            Text("128").tag(128)
                            Text("256").tag(256)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                    }
                    .disabled(!tempSettings.pngquantMarkdownExportEnabled)
                }
            }

            SettingsSection(
                "Polling",
                systemImage: "timer",
                footer: "A shorter interval captures changes sooner but uses more power."
            ) {
                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Clipboard polling interval")
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
