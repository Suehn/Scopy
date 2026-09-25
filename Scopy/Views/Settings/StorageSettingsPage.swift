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
                "Limits",
                systemImage: "gauge.with.dots.needle.bottom.50percent",
                footer: "Past a limit, older items are cleaned up automatically; pinned items are kept. The content size limit counts item content (SUM(size_bytes)), not the database file size. With “Clean up images only”, automatic cleanup deletes only image items and keeps text and rich text; if most space is used by text or pinned images, usage may stay above the limit."
            ) {
                SettingsCardRow {
                    LabeledContent("History item limit") {
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
                    LabeledContent("Content size limit") {
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
                    Toggle("Clean up images only (text is kept)", isOn: $tempSettings.cleanupImagesOnly)
                        .accessibilityIdentifier("Settings.CleanupImagesOnlyToggle")
                }
            }

            SettingsSection("Current usage", systemImage: "chart.pie") {
                if isLoading {
                    SettingsCardRow {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } else if let stats = storageStats {
                    SettingsCardRow {
                        LabeledContent("Items") {
                            Text("\(stats.itemCount) / \(tempSettings.maxItems)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("Database") {
                            Text(Localization.formatBytes(stats.databaseSizeBytes)).foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("External storage") {
                            Text(Localization.formatBytes(stats.externalStorageSizeBytes)).foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("Thumbnails") {
                            Text(Localization.formatBytes(stats.thumbnailSizeBytes)).foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        LabeledContent("Total") {
                            Text(Localization.formatBytes(stats.totalSizeBytes))
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsCardDivider()
                    SettingsCardRow {
                        HStack {
                            Spacer()
                            Button(action: onRefresh) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.link)
                        }
                    }
                } else {
                    SettingsCardRow {
                        Text("Storage statistics unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection("Location", systemImage: "folder") {
                SettingsCardRow {
                    LabeledContent("Database location") {
                        Text(storageStats?.databasePath ?? "~/Library/Application Support/Scopy/")
                            .foregroundStyle(.secondary)
                            .font(ScopyTypography.pathLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Button("Show in Finder") {
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
