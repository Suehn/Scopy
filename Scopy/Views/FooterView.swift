import SwiftUI
import ScopyKit

/// 底部状态栏视图
struct FooterView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel

    /// v0.22: 修复 -1 显示 bug - 当 totalCount=-1 时表示"未知"，显示 "50+ items"
    private var summaryText: String {
        if !historyViewModel.searchQuery.isEmpty {
            // 搜索模式：显示当前结果数
            if historyViewModel.totalCount < 0 {
                return "\(historyViewModel.items.count)+ results"
            }
            return "\(historyViewModel.items.count) results"
        } else if historyViewModel.totalCount < 0 {
            // totalCount=-1 表示未知总数（v0.13 LIMIT+1 技巧）
            return "\(historyViewModel.loadedCount)+ items"
        } else if historyViewModel.loadedCount < historyViewModel.totalCount {
            return "\(historyViewModel.loadedCount)/\(historyViewModel.totalCount) items"
        } else {
            return "\(historyViewModel.totalCount) items"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Subtle top separator
            Divider()
                .background(ScopyColors.separator.opacity(ScopySize.Opacity.light))

            HStack(spacing: ScopySpacing.md) {
                // Status Info - clean text without container
                HStack(spacing: ScopySpacing.sm) {
                    Text(summaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text("·")
                    Text(settingsViewModel.storageSizeText)
                        .lineLimit(1)
                        .fixedSize()

                    if historyViewModel.canLoadMore && !historyViewModel.searchQuery.isEmpty {
                        Text("·")
                        if historyViewModel.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Button("Load more") {
                                Task { await historyViewModel.loadMore() }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ScopyColors.accent)
                        }
                    }
                }
                .font(ScopyTypography.microMono)
                .foregroundStyle(ScopyColors.tertiaryText)

                Spacer()

                // Action Buttons - v0.15: Single delete + Settings + Quit
                HStack(spacing: ScopySpacing.xs) {
                    FooterButton(icon: "trash", shortcut: "⌥⌫") {
                        Task { await historyViewModel.deleteSelectedItem() }
                    }
                    .help("Delete Selected")

                    FooterButton(icon: "gearshape", shortcut: "⌘,") {
                        appState.openSettingsHandler?()
                    }
                    .help("Settings")

                    FooterButton(icon: "power", shortcut: "⌘Q") {
                        NSApp.terminate(nil)
                    }
                    .help("Quit")
                }
            }
            .padding(.horizontal, ScopySpacing.lg)
            .padding(.vertical, ScopySpacing.xs)
        }
        // v0.10.3-fix: 固定高度防止搜索时布局跳动
        .frame(height: ScopySize.Height.footer)
        .frame(maxWidth: .infinity)
    }
}

/// 底部按钮组件 - 仅图标 + 快捷键
struct FooterButton: View {
    let icon: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ScopySpacing.xxs) {
                Image(systemName: icon)
                    .font(.system(size: ScopySize.Icon.xs))
                Text(shortcut)
                    .font(.system(size: ScopySize.Icon.pin, weight: .medium))
                    .foregroundStyle(ScopyColors.tertiaryText.opacity(ScopySize.Opacity.strong))
            }
            .padding(.horizontal, ScopySpacing.sm)
            .padding(.vertical, ScopySize.Width.pinIndicator)
            .background(isHovered ? ScopyColors.secondaryBackground : Color.clear)
            .foregroundStyle(isHovered ? ScopyColors.text : ScopyColors.mutedText)
            .clipShape(RoundedRectangle(cornerRadius: ScopySize.Corner.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
