import SwiftUI
import ScopyKit

struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsPageHeaderIcon(systemName: page.icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title)
                    .fontWeight(.bold)

                if let subtitle = page.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SettingsPageContainer<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(page: page)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
                .background(ScopyColors.background)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(ScopyColors.background)
    }
}

private struct SettingsPageHeaderIcon: View {
    let systemName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(ScopyColors.secondaryBackground)
                .frame(width: 30, height: 30) // Slightly smaller for header

            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }
}
