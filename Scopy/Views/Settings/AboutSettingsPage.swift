import AppKit
import SwiftUI

struct AboutSettingsPage: View {
    @State private var performanceSummary: PerformanceSummary?
    @State private var memoryUsageMB: Double = 0
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        SettingsPageContainer(page: .about) {
            Section {
                HStack(spacing: ScopySpacing.md) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppVersion.appName)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("版本 \(AppVersion.fullVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("构建日期 \(AppVersion.buildDate)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, ScopySpacing.xs)
            } header: {
                Text("应用信息")
            }

            Section {
                LazyVGrid(
                    columns: [GridItem(.flexible(minimum: 120), spacing: ScopySpacing.md), GridItem(.flexible(minimum: 120))],
                    alignment: .leading,
                    spacing: ScopySpacing.sm
                ) {
                    SettingsFeatureRow(icon: "infinity", text: "无限历史", tint: .purple)
                    SettingsFeatureRow(icon: "magnifyingglass", text: "高性能搜索", tint: .blue)
                    SettingsFeatureRow(icon: "externaldrive", text: "分层存储", tint: .orange)
                    SettingsFeatureRow(icon: "checkmark.seal", text: "去重写入", tint: .green)
                    SettingsFeatureRow(icon: "keyboard", text: "全局快捷键", tint: .indigo)
                    SettingsFeatureRow(icon: "bolt", text: "低延迟体验", tint: .teal)
                }
                .padding(.vertical, ScopySpacing.xs)
            } header: {
                Text("特性")
            }

            Section {
                LabeledContent("搜索") {
                    Text(searchValue)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("首屏") {
                    Text(loadValue)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("内存") {
                    Text(String(format: "%.1f MB", memoryUsageMB))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button("刷新") {
                    refreshPerformance()
                }
            } header: {
                Text("性能（进程内采样）")
            }

            Section {
                Link("GitHub", destination: URL(string: "https://github.com/Suehn/Scopy")!)
                Link("反馈问题", destination: URL(string: "https://github.com/Suehn/Scopy/issues/new")!)
            } header: {
                Text("链接")
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
        return "\(formatMs(summary.searchP95)) P95 / \(formatMs(summary.searchAvg)) avg (\(summary.searchSamples) samples)"
    }

    private var loadValue: String {
        guard let summary = performanceSummary, summary.loadSamples > 0 else { return "N/A" }
        return "\(formatMs(summary.loadP95)) P95 / \(formatMs(summary.loadAvg)) avg (\(summary.loadSamples) samples)"
    }

    private func refreshPerformance() {
        Task {
            performanceSummary = await PerformanceMetrics.shared.getSummary()
        }

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            memoryUsageMB = Double(info.resident_size) / 1024 / 1024
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
