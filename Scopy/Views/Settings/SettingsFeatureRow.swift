import SwiftUI

struct SettingsFeatureRow: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: ScopySpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 22, height: 22)

            Text(text)
                .font(.subheadline)
        }
    }
}
