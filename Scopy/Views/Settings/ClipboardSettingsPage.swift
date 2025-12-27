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
                "历史图片优化（pngquant）",
                systemImage: "photo",
                footer: "Scopy 已内置 pngquant，无需额外安装。你可以在历史列表每条图片右侧点击“优化”按钮手动压缩并覆盖原图；也可以开启自动压缩，让新图片写入历史前自动压缩。两者共用同一套参数。"
            ) {
                SettingsCardRow {
                    Toggle("自动压缩新图片", isOn: $tempSettings.pngquantCopyImageEnabled)
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
        }
    }
}
