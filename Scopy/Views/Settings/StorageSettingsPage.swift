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
            Section {
                Picker("历史条目上限", selection: $tempSettings.maxItems) {
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                    Text("100,000").tag(100000)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Settings.MaxItemsPicker")

                Picker("内联存储上限", selection: $tempSettings.maxStorageMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Settings.MaxStoragePicker")
            } header: {
                Label("限制", systemImage: "gauge.with.dots.needle.bottom.50percent")
            } footer: {
                Text("超过上限后会自动清理较旧的条目（Pinned 会被保留）。")
                    .foregroundStyle(.secondary)
            }

            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("正在读取…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let stats = storageStats {
                    LabeledContent("条目数") {
                        Text("\(stats.itemCount) / \(tempSettings.maxItems)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("数据库") {
                        Text(stats.databaseSizeText).foregroundStyle(.secondary)
                    }
                    LabeledContent("外部存储") {
                        Text(stats.externalStorageSizeText).foregroundStyle(.secondary)
                    }
                    LabeledContent("缩略图") {
                        Text(stats.thumbnailSizeText).foregroundStyle(.secondary)
                    }
                    LabeledContent("总计") {
                        Text(stats.totalSizeText)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }

                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } else {
                    Text("无法读取存储统计")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("当前占用", systemImage: "chart.pie")
            }

            Section {
                LabeledContent("数据库位置") {
                    Text(storageStats?.databasePath ?? "~/Library/Application Support/Scopy/")
                        .foregroundStyle(.secondary)
                        .font(ScopyTypography.pathLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("在 Finder 中显示") {
                    let scopyDir: URL
                    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                        scopyDir = appSupport.appendingPathComponent("Scopy")
                    } else {
                        scopyDir = FileManager.default.homeDirectoryForCurrentUser
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([scopyDir])
                }
            } header: {
                Label("位置", systemImage: "folder")
            }
        }
    }
}
