import AppKit
import SwiftUI
import ScopyKit

struct AboutSettingsPage: View {
    let checkForUpdates: (() -> Void)?

    @State private var performanceSummary: PerformanceSummary?
    @State private var ingestSummary: ClipboardIngestSummary?
    @State private var memoryUsageMB: Double = 0
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        SettingsPageContainer(page: .about) {
            SettingsSection("Info", systemImage: "info.circle") {
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
                                Text("Version \(AppVersion.fullVersion)")
                                Text("Built \(AppVersion.buildDate)")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button("Check for Updates…") {
                            checkForUpdates?()
                        }
                        .disabled(checkForUpdates == nil)
                        .accessibilityIdentifier("Settings.CheckForUpdates")
                    }
                }
            }

            SettingsSection("Features", systemImage: "sparkles") {
                SettingsCardRow {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        FeatureItem(text: "Unlimited history", icon: "infinity", color: .purple)
                        FeatureItem(text: "Fast search", icon: "magnifyingglass", color: .blue)
                        FeatureItem(text: "Tiered storage", icon: "externaldrive", color: .orange)
                        FeatureItem(text: "Deduplicated capture", icon: "checkmark.seal", color: .green)
                        FeatureItem(text: "Global hotkey", icon: "keyboard", color: .indigo)
                        FeatureItem(text: "Low latency", icon: "bolt", color: .teal)
                    }
                }
            }

            SettingsSection("Diagnostics", systemImage: "stethoscope") {
                SettingsCardRow {
                    DisclosureGroup("Performance and ingest metrics") {
                        VStack(alignment: .leading, spacing: 0) {
                            LabeledContent("Search latency") {
                                Text(searchValue).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            LabeledContent("First page load") {
                                Text(loadValue).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            LabeledContent("Memory") {
                                Text(String(format: "%.1f MB", memoryUsageMB))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            Divider()
                            LabeledContent("Queued / active") {
                                Text("\(ingestPendingValue) / \(ingestActiveValue)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            LabeledContent("Persisted backlog") {
                                Text(ingestPersistedValue)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            LabeledContent("soft limit / replay") {
                                Text("\(ingestSoftLimitValue) / \(ingestReplayValue)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            LabeledContent("changeCount jumps") {
                                Text("\(ingestJumpValue) (max Δ\(ingestMaxDeltaValue))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            LabeledContent("Last persisted / ack") {
                                Text("\(ingestPersistedAtValue) / \(ingestAckAtValue)")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            HStack {
                                Spacer()
                                Button("Refresh", action: refreshPerformance)
                                    .buttonStyle(.link)
                                    .controlSize(.small)
                            }
                            .padding(.top, 6)
                        }
                        .padding(.top, 6)
                    }
                }
            }

            SettingsSection("Links", systemImage: "link") {
                SettingsCardRow {
                    Link(destination: URL(string: "https://github.com/Suehn/Scopy")!) {
                        Label("GitHub Repository", systemImage: "arrow.up.right.square")
                    }
                }

                SettingsCardDivider()

                SettingsCardRow {
                    Link(destination: URL(string: "https://github.com/Suehn/Scopy/issues/new")!) {
                        Label("Send Feedback", systemImage: "bubble.left.and.bubble.right")
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
            let ingest = await ClipboardIngestMetrics.shared.getSummary()
            let currentMemoryUsageMB = readMemoryUsageMB()
            await MainActor.run {
                performanceSummary = summary
                ingestSummary = ingest
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

    private var ingestPendingValue: String {
        "\(ingestSummary?.pendingCount ?? 0)"
    }

    private var ingestActiveValue: String {
        "\(ingestSummary?.activeCount ?? 0)"
    }

    private var ingestPersistedValue: String {
        "\(ingestSummary?.persistedCount ?? 0)"
    }

    private var ingestSoftLimitValue: String {
        "\(ingestSummary?.softLimitHitCount ?? 0)"
    }

    private var ingestReplayValue: String {
        "\(ingestSummary?.replayCount ?? 0)"
    }

    private var ingestJumpValue: String {
        "\(ingestSummary?.changeJumpCount ?? 0)"
    }

    private var ingestMaxDeltaValue: String {
        "\(ingestSummary?.maxObservedChangeDelta ?? 1)"
    }

    private var ingestPersistedAtValue: String {
        formatTimestamp(ingestSummary?.lastPersistedAt)
    }

    private var ingestAckAtValue: String {
        formatTimestamp(ingestSummary?.lastAcknowledgedAt)
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "N/A" }
        return date.formatted(date: .omitted, time: .standard)
    }
}

private struct FeatureItem: View {
    let text: LocalizedStringKey
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
