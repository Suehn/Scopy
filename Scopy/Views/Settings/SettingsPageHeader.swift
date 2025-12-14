import SwiftUI

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ScopySpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.top, ScopySpacing.sm)
        .padding(.bottom, ScopySpacing.md)
    }
}

struct SettingsPageContainer<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(title: page.title, subtitle: page.subtitle, systemImage: page.icon)
            Form {
                content()
            }
            .formStyle(.grouped)
        }
    }
}

