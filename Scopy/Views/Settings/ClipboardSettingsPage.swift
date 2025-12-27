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
                "历史图片压缩（pngquant）",
                systemImage: "photo",
                footer: "开启后，图片写入 Scopy 历史前会先用 pngquant 做有损压缩并覆盖原图（降低 content/ 占用）。默认关闭。"
            ) {
                SettingsCardRow {
                    Toggle("压缩历史图片", isOn: $tempSettings.pngquantCopyImageEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("质量范围")
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
                    .disabled(!tempSettings.pngquantCopyImageEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("速度")
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
                    .disabled(!tempSettings.pngquantCopyImageEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    LabeledContent("颜色数") {
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
                    .disabled(!tempSettings.pngquantCopyImageEnabled)
                }
            }

            SettingsSection(
                "导出 PNG 压缩（pngquant）",
                systemImage: "square.and.arrow.up",
                footer: "开启后，Markdown/LaTeX 导出 PNG 到剪贴板时会先用 pngquant 压缩，并仅输出压缩后的 PNG（会进入历史）。默认开启。"
            ) {
                SettingsCardRow {
                    Toggle("压缩导出 PNG", isOn: $tempSettings.pngquantMarkdownExportEnabled)
                }

                SettingsCardDivider()

                SettingsCardRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("质量范围")
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
                            Text("速度")
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
                    LabeledContent("颜色数") {
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

            SettingsSection(
                "PNG 优化（pngquant）",
                systemImage: "wand.and.stars",
                footer: "pngquant 是外部命令行工具：留空会优先使用应用内置 Tools/pngquant（若存在），否则自动探测常见路径（如 /opt/homebrew/bin/pngquant）。导出 Markdown/LaTeX PNG 默认会压缩并覆盖输出内容；普通图片写入历史默认不压缩。"
            ) {
                SettingsCardRow {
                    LabeledContent("pngquant 路径") {
                        TextField("留空自动探测", text: $tempSettings.pngquantBinaryPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .accessibilityIdentifier("Settings.PngquantBinaryPathField")
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Toggle("导出 Markdown/LaTeX PNG 时压缩", isOn: $tempSettings.pngquantMarkdownExportEnabled)
                        .accessibilityIdentifier("Settings.PngquantMarkdownExportEnabledToggle")
                }

                if tempSettings.pngquantMarkdownExportEnabled {
                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("导出质量") {
                            HStack(spacing: 8) {
                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { tempSettings.pngquantMarkdownExportQualityMin },
                                        set: { newValue in
                                            tempSettings.pngquantMarkdownExportQualityMin = newValue
                                            if tempSettings.pngquantMarkdownExportQualityMax < newValue {
                                                tempSettings.pngquantMarkdownExportQualityMax = newValue
                                            }
                                        }
                                    )
                                ) {
                                    ForEach(stride(from: 0, through: 100, by: 5).map { $0 }, id: \.self) { v in
                                        Text("\(v)").tag(v)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 72)

                                Text("–")
                                    .foregroundStyle(.secondary)

                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { tempSettings.pngquantMarkdownExportQualityMax },
                                        set: { newValue in
                                            tempSettings.pngquantMarkdownExportQualityMax = newValue
                                            if tempSettings.pngquantMarkdownExportQualityMin > newValue {
                                                tempSettings.pngquantMarkdownExportQualityMin = newValue
                                            }
                                        }
                                    )
                                ) {
                                    ForEach(stride(from: 0, through: 100, by: 5).map { $0 }, id: \.self) { v in
                                        Text("\(v)").tag(v)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 72)
                            }
                            .accessibilityIdentifier("Settings.PngquantMarkdownExportQualityRange")
                        }
                    }

                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("导出速度") {
                            Picker("", selection: $tempSettings.pngquantMarkdownExportSpeed) {
                                ForEach(Array(1...11), id: \.self) { v in
                                    Text("\(v)").tag(v)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: ScopySize.Width.pickerMenu)
                            .accessibilityIdentifier("Settings.PngquantMarkdownExportSpeedPicker")
                        }
                    }

                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("导出颜色数") {
                            Picker("", selection: $tempSettings.pngquantMarkdownExportColors) {
                                ForEach([16, 32, 64, 128, 256], id: \.self) { v in
                                    Text("\(v)").tag(v)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: ScopySize.Width.pickerMenu)
                            .accessibilityIdentifier("Settings.PngquantMarkdownExportColorsPicker")
                        }
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Toggle("图片写入历史前压缩", isOn: $tempSettings.pngquantCopyImageEnabled)
                        .accessibilityIdentifier("Settings.PngquantCopyImageEnabledToggle")
                }

                if tempSettings.pngquantCopyImageEnabled {
                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("写入质量") {
                            HStack(spacing: 8) {
                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { tempSettings.pngquantCopyImageQualityMin },
                                        set: { newValue in
                                            tempSettings.pngquantCopyImageQualityMin = newValue
                                            if tempSettings.pngquantCopyImageQualityMax < newValue {
                                                tempSettings.pngquantCopyImageQualityMax = newValue
                                            }
                                        }
                                    )
                                ) {
                                    ForEach(stride(from: 0, through: 100, by: 5).map { $0 }, id: \.self) { v in
                                        Text("\(v)").tag(v)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 72)

                                Text("–")
                                    .foregroundStyle(.secondary)

                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { tempSettings.pngquantCopyImageQualityMax },
                                        set: { newValue in
                                            tempSettings.pngquantCopyImageQualityMax = newValue
                                            if tempSettings.pngquantCopyImageQualityMin > newValue {
                                                tempSettings.pngquantCopyImageQualityMin = newValue
                                            }
                                        }
                                    )
                                ) {
                                    ForEach(stride(from: 0, through: 100, by: 5).map { $0 }, id: \.self) { v in
                                        Text("\(v)").tag(v)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 72)
                            }
                            .accessibilityIdentifier("Settings.PngquantCopyImageQualityRange")
                        }
                    }

                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("写入速度") {
                            Picker("", selection: $tempSettings.pngquantCopyImageSpeed) {
                                ForEach(Array(1...11), id: \.self) { v in
                                    Text("\(v)").tag(v)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: ScopySize.Width.pickerMenu)
                            .accessibilityIdentifier("Settings.PngquantCopyImageSpeedPicker")
                        }
                    }

                    SettingsCardDivider()

                    SettingsCardRow {
                        LabeledContent("写入颜色数") {
                            Picker("", selection: $tempSettings.pngquantCopyImageColors) {
                                ForEach([16, 32, 64, 128, 256], id: \.self) { v in
                                    Text("\(v)").tag(v)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: ScopySize.Width.pickerMenu)
                            .accessibilityIdentifier("Settings.PngquantCopyImageColorsPicker")
                        }
                    }
                }
            }
        }
    }
}
