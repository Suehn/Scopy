import AppKit
import SwiftUI

struct AboutSettingsPage: View {
    @State private var performanceSummary: PerformanceSummary?
    @State private var memoryUsageMB: Double = 0
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        SettingsPageContainer(page: .about) {
            SettingsSection("信息", systemImage: "info.circle") {
                SettingsCardRow {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .accessibilityLabel("App Icon")

                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppVersion.appName)
                                .font(.title3)
                                .fontWeight(.semibold)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("版本 \(AppVersion.fullVersion)")
                                Text("构建于 \(AppVersion.buildDate)")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            SettingsSection("特性", systemImage: "sparkles") {
                SettingsCardRow {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        FeatureItem(text: "无限历史", icon: "infinity", color: .purple)
                        FeatureItem(text: "高性能搜索", icon: "magnifyingglass", color: .blue)
                        FeatureItem(text: "分层存储", icon: "externaldrive", color: .orange)
                        FeatureItem(text: "去重写入", icon: "checkmark.seal", color: .green)
                        FeatureItem(text: "全局快捷键", icon: "keyboard", color: .indigo)
                        FeatureItem(text: "低延迟体验", icon: "bolt", color: .teal)
                    }
                }
            }

            SettingsSection("性能监测", systemImage: "speedometer") {
                SettingsCardRow {
                    LabeledContent("搜索延迟") {
                        Text(searchValue).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                SettingsCardDivider()
                SettingsCardRow {
                    LabeledContent("首屏加载") {
                        Text(loadValue).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                SettingsCardDivider()
                SettingsCardRow {
                    LabeledContent("内存占用") {
                        Text(String(format: "%.1f MB", memoryUsageMB))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsCardDivider()
                SettingsCardRow {
                    HStack {
                        Spacer()
                        Button("刷新数据", action: refreshPerformance)
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
            }

            SettingsSection("链接", systemImage: "link") {
                SettingsCardRow {
                    Link(destination: URL(string: "https://github.com/Suehn/Scopy")!) {
                        Label("GitHub 仓库", systemImage: "arrow.up.right.square")
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Link(destination: URL(string: "https://github.com/Suehn/Scopy/issues/new")!) {
                        Label("提交反馈", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        }
        .onAppear {
            refreshPerformance()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    private var searchValue: String {
        guard let summary = performanceSummary, summary.searchSamples > 0 else { return "N/A" }
        return "\(formatMs(summary.searchP95)) / \(formatMs(summary.searchAvg)) avg"
    }

    private var loadValue: String {
        guard let summary = performanceSummary, summary.loadSamples > 0 else { return "N/A" }
        return "\(formatMs(summary.loadP95)) / \(formatMs(summary.loadAvg)) avg"
    }

    private func refreshPerformance() {
        Task {
            let summary = await PerformanceMetrics.shared.getSummary()
            let currentMemoryUsageMB = readMemoryUsageMB()
            await MainActor.run {
                performanceSummary = summary
                memoryUsageMB = currentMemoryUsageMB
            }
        }
    }

    private func startAutoRefresh() {
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                refreshPerformance()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func readMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }

    private func formatMs(_ ms: Double) -> String {
        if ms < 1 {
            return String(format: "%.2f ms", ms)
        } else if ms < 10 {
            return String(format: "%.1f ms", ms)
        } else {
            return String(format: "%.0f ms", ms)
        }
    }
}

private struct FeatureItem: View {
    let text: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}
