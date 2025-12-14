import SwiftUI

struct AboutSettingsPage: View {
    @State private var performanceSummary: PerformanceSummary?
    @State private var memoryUsageMB: Double = 0
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: ScopySpacing.xl) {
            SettingsPageHeader(title: SettingsPage.about.title, subtitle: nil, systemImage: SettingsPage.about.icon)

            GroupBox {
                VStack(alignment: .leading, spacing: ScopySpacing.sm) {
                    HStack(spacing: ScopySpacing.md) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppVersion.appName)
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text("版本 \(AppVersion.fullVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("构建日期 \(AppVersion.buildDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } label: {
                Text("应用信息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ScopySpacing.sm) {
                    SettingsFeatureRow(icon: "infinity", text: "无限历史")
                    SettingsFeatureRow(icon: "magnifyingglass", text: "高性能搜索")
                    SettingsFeatureRow(icon: "externaldrive", text: "分层存储")
                    SettingsFeatureRow(icon: "checkmark.circle", text: "去重写入")
                    SettingsFeatureRow(icon: "keyboard", text: "全局快捷键")
                    SettingsFeatureRow(icon: "bolt", text: "低延迟体验")
                }
            } label: {
                Text("特性")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: ScopySpacing.md) {
                    metricRow(title: "搜索", value: searchValue)
                    metricRow(title: "首屏", value: loadValue)
                    metricRow(title: "内存", value: String(format: "%.1f MB", memoryUsageMB))
                }
            } label: {
                HStack {
                    Text("性能（进程内采样）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: refreshPerformance) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            HStack(spacing: ScopySpacing.xl) {
                Link("GitHub", destination: URL(string: "https://github.com/Suehn/Scopy")!)
                Link("反馈问题", destination: URL(string: "https://github.com/Suehn/Scopy/issues/new")!)
            }
            .font(.caption)
            .foregroundStyle(.blue)

            Spacer()
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

    private func metricRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .frame(width: ScopySize.Width.statLabel, alignment: .leading)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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

