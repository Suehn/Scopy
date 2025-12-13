import SwiftUI
import ScopyKit

struct EmptyStateView: View {
    let hasFilters: Bool
    let openSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: ScopySpacing.md) {
            Image(systemName: hasFilters ? ScopyIcons.search : ScopyIcons.tray)
                .font(.system(size: ScopySize.Icon.empty))
                .foregroundStyle(ScopyColors.mutedText)
            VStack(spacing: ScopySpacing.xs) {
                Text(hasFilters ? "No results" : "No items yet")
                    .font(ScopyTypography.title)
                Text(hasFilters ? "Try clearing filters or adjust search" : "New copies will appear here")
                    .font(ScopyTypography.caption)
                    .foregroundStyle(ScopyColors.mutedText)
            }
            if !hasFilters, let openSettings {
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: ScopyIcons.settings)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ScopySpacing.xl)
    }
}
