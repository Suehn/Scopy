import SwiftUI
import ScopyKit

/// The panel footer: item count, storage size, and the delete/settings/quit buttons.
struct FooterView: View {
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel

    let openSettings: (() -> Void)?

    /// A totalCount of -1 means the total is unknown (the page query fetched LIMIT + 1 rows).
    private var summaryText: String {
        if historyViewModel.hasActiveFilters {
            if historyViewModel.totalCount < 0 {
                return String(localized: "\(historyViewModel.items.count)+ results")
            }
            return String(localized: "\(historyViewModel.items.count) results")
        } else if historyViewModel.totalCount < 0 {
            return String(localized: "\(historyViewModel.loadedCount)+ items")
        } else if historyViewModel.loadedCount < historyViewModel.totalCount {
            return String(localized: "\(historyViewModel.loadedCount)/\(historyViewModel.totalCount) items")
        } else {
            return String(localized: "\(historyViewModel.totalCount) items")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Subtle top separator
            Divider()
                .background(ScopyColors.separator.opacity(ScopySize.Opacity.light))

            HStack(spacing: ScopySpacing.md) {
                // Status Info - clean text without container. A failed action takes this slot so
                // it stays visible without changing the footer's fixed height.
                if let actionErrorMessage = historyViewModel.actionErrorMessage {
                    HStack(spacing: ScopySpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(actionErrorMessage)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.warning)
                    .accessibilityIdentifier("Footer.ActionError")
                    .onTapGesture { historyViewModel.clearActionError() }
                } else if historyViewModel.undoableDeletionID != nil {
                    HStack(spacing: ScopySpacing.xs) {
                        Text("Deleted")
                        Text(verbatim: "·")
                        Button("Undo") { Task { await historyViewModel.undoPendingDeletion() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(ScopyColors.accent)
                    }
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.tertiaryText)
                    .accessibilityIdentifier("Footer.UndoDeletion")
                } else if let fetchFailureMessage = historyViewModel.fetchFailureMessage {
                    HStack(spacing: ScopySpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(fetchFailureMessage)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button("Retry") { historyViewModel.search() }
                            .buttonStyle(.plain)
                            .foregroundStyle(ScopyColors.accent)
                    }
                    .font(ScopyTypography.microMono)
                    .foregroundStyle(ScopyColors.warning)
                    .accessibilityIdentifier("Footer.FetchFailure")
                } else {
                HStack(spacing: ScopySpacing.sm) {
                    Text(summaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text("·")
                    Text(settingsViewModel.storageSizeText)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(ScopyTypography.microMono)
                .foregroundStyle(ScopyColors.tertiaryText)
                }

                Spacer()

                HStack(spacing: ScopySpacing.xs) {
                    FooterButton(icon: "trash", shortcut: "⌥⌫") {
                        Task { await historyViewModel.deleteSelectedItem() }
                    }
                    .help("Delete Selected")

                    FooterButton(icon: "gearshape", shortcut: "⌘,") {
                        openSettings?()
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
        // A fixed height keeps the list from moving when the status text changes.
        .frame(height: ScopySize.Height.footer)
        .frame(maxWidth: .infinity)
    }
}

/// Icon plus shortcut hint.
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
