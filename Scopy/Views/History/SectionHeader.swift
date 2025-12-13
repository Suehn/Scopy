import SwiftUI
import ScopyKit

struct SectionHeader: View {
    let title: String
    let count: Int
    var performanceSummary: PerformanceSummary? = nil
    /// v0.16.2: 可折叠支持
    var isCollapsible: Bool = false
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack {
            // v0.16.2: 折叠指示器
            if isCollapsible {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ScopyColors.tertiaryText)
                    .frame(width: 12)
            }

            Text("\(title) · \(count)")
                .font(ScopyTypography.caption)
                .fontWeight(.medium)
                .foregroundStyle(ScopyColors.tertiaryText)
                .monospacedDigit()

            if let summary = performanceSummary, title == "Recent" {
                Spacer()
                HStack(spacing: ScopySpacing.md) {
                    if summary.searchSamples > 0 {
                        Text("Search: \(summary.formattedSearchAvg)")
                    }
                    if summary.loadSamples > 0 {
                        Text("Load: \(summary.formattedLoadAvg)")
                    }
                }
                .font(.system(size: ScopyTypography.Size.micro, weight: .regular, design: .monospaced))
                .foregroundStyle(ScopyColors.tertiaryText.opacity(ScopySize.Opacity.strong))
            }

            Spacer()
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.top, ScopySpacing.md)
        .padding(.bottom, ScopySpacing.xs)
        // v0.16.2: 可点击折叠
        .background(isCollapsible && isHovered ? ScopyColors.hover.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsible {
                onToggle?()
            }
        }
        .onHover { hovering in
            if isCollapsible {
                isHovered = hovering
            }
        }
    }
}
