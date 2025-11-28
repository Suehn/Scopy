import SwiftUI

/// 底部状态栏视图
struct FooterView: View {
    @Environment(AppState.self) private var appState
    @State private var showClearConfirmation = false

    private var summaryText: String {
        if !appState.searchQuery.isEmpty {
            return "\(appState.items.count) results"
        } else if appState.loadedCount < appState.totalCount {
            return "\(appState.loadedCount)/\(appState.totalCount) items"
        } else {
            return "\(appState.totalCount) items"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Subtle top separator
            Divider()
                .background(ScopyColors.separator.opacity(0.3))

            HStack(spacing: ScopySpacing.md) {
                // Status Info - clean text without container
                HStack(spacing: ScopySpacing.sm) {
                    Text(summaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text("·")
                    Text(appState.storageSizeText)
                        .lineLimit(1)
                        .fixedSize()

                    if appState.canLoadMore && !appState.searchQuery.isEmpty {
                        Text("·")
                        if appState.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Button("Load more") {
                                Task { await appState.loadMore() }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ScopyColors.accent)
                        }
                    }
                }
                .font(ScopyTypography.microMono)
                .foregroundStyle(ScopyColors.tertiaryText)

                Spacer()

                // Action Buttons - refined styling
                HStack(spacing: ScopySpacing.xs) {
                    FooterButton(icon: "trash", shortcut: "⌘⌫") {
                        showClearConfirmation = true
                    }
                    .help("Clear All")

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
        .alert("Clear All History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task { await appState.clearAll() }
            }
        } message: {
            Text("This will permanently delete all \(appState.totalCount) items. This action cannot be undone.")
        }
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
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: ScopySize.Icon.xs))
                Text(shortcut)
                    .font(.system(size: ScopySize.Icon.pin, weight: .medium))
                    .foregroundStyle(ScopyColors.tertiaryText.opacity(0.8))
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
