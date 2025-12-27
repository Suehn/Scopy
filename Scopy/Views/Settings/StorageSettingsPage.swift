import AppKit
import SwiftUI
import ScopyKit

struct StorageSettingsPage: View {
    @Binding var tempSettings: SettingsDTO
    let storageStats: StorageStatsDTO?
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        SettingsPageContainer(page: .storage) {
            SettingsSection(
                "限制",
                systemImage: "gauge.with.dots.needle.bottom.50percent",
                footer: "超过上限后会自动清理较旧的条目（Pinned 会被保留）。“内容估算上限”按条目内容体积（SUM(size_bytes)）计算，不等同于数据库文件大小。开启“仅清理图片”后，自动清理只会删除图片条目（文本/富文本等会永久保留）；若主要占用来自文本或已 Pinned 图片，可能无法降到上限。"
            ) {
                SettingsCardRow {
                    LabeledContent("历史条目上限") {
                        Picker("", selection: $tempSettings.maxItems) {
                            Text("1,000").tag(1000)
                            Text("5,000").tag(5000)
                            Text("10,000").tag(10000)
                            Text("50,000").tag(50000)
                            Text("100,000").tag(100000)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                        .accessibilityIdentifier("Settings.MaxItemsPicker")
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    LabeledContent("内容估算上限") {
                        Picker("", selection: $tempSettings.maxStorageMB) {
                            Text("100 MB").tag(100)
                            Text("200 MB").tag(200)
                            Text("500 MB").tag(500)
                            Text("1 GB").tag(1000)
                            Text("2 GB").tag(2000)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: ScopySize.Width.pickerMenu)
                        .accessibilityIdentifier("Settings.MaxStoragePicker")
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Toggle("仅清理图片（文本永久保留）", isOn: $tempSettings.cleanupImagesOnly)
                        .accessibilityIdentifier("Settings.CleanupImagesOnlyToggle")
                }
            }

            SettingsSection("当前占用", systemImage: "chart.pie") {
                if isLoading {
                    SettingsCardRow {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Text("正在读取…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } else if let stats = storageStats {
                    SettingsCardRow {
                        LabeledContent("条目数") {
                            Text("\(stats.itemCount) / \(tempSettings.maxItems)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("数据库") {
                            Text(stats.databaseSizeText).foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("外部存储") {
                            Text(stats.externalStorageSizeText).foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("缩略图") {
                            Text(stats.thumbnailSizeText).foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("总计") {
                            Text(stats.totalSizeText)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        HStack {
                            Spacer()
                            Button(action: onRefresh) {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.link)
                        }
                    }
                } else {
                    SettingsCardRow {
                        Text("无法读取存储统计")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection("位置", systemImage: "folder") {
                SettingsCardRow {
                    LabeledContent("数据库位置") {
                        Text(storageStats?.databasePath ?? "~/Library/Application Support/Scopy/")
                            .foregroundStyle(.secondary)
                            .font(ScopyTypography.pathLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Button("在 Finder 中显示") {
                        let scopyDir: URL
                        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                            scopyDir = appSupport.appendingPathComponent("Scopy")
                        } else {
                            scopyDir = FileManager.default.homeDirectoryForCurrentUser
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([scopyDir])
                    }
                }
            }
        }
    }
}
