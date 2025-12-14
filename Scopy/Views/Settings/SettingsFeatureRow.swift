import SwiftUI

struct SettingsFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: ScopySpacing.lg - ScopySpacing.sm) {
            Image(systemName: icon)
                .frame(width: ScopySize.Icon.md)
                .foregroundStyle(.blue)
            Text(text)
                .font(.subheadline)
        }
    }
}

