import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        systemImage: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScopySpacing.sm) {
            SettingsSectionHeader(title: title, systemImage: systemImage)

            SettingsCard {
                content()
            }

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .symbolRenderingMode(.hierarchical)
            } else {
                Text(title)
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(ScopyColors.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ScopyColors.separator.opacity(ScopySize.Opacity.light), lineWidth: ScopySize.Stroke.thin)
        )
    }
}

struct SettingsCardRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}

struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}
