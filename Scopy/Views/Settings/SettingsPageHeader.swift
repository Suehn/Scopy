import SwiftUI

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: ScopySpacing.md) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 28, height: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

struct SettingsPageContainer<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ScopySpacing.sm) {
            SettingsPageHeader(title: page.title, subtitle: page.subtitle, systemImage: page.icon)
                .padding(.top, ScopySpacing.md)
                .padding(.horizontal, ScopySpacing.xl)
            Form {
                content()
            }
            .formStyle(.grouped)
            .padding(.horizontal, ScopySpacing.xl)
            .padding(.top, -ScopySpacing.sm)
        }
        .padding(.bottom, ScopySpacing.xl)
    }
}
