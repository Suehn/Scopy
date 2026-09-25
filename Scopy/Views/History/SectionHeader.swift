import SwiftUI
import ScopyKit

struct SectionHeader: View {
    let title: String
    let count: Int
    var isScrolling: Bool = false
    var isCollapsible: Bool = false
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack {
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

            Spacer()
        }
        .padding(.horizontal, ScopySpacing.md)
        .padding(.top, ScopySpacing.md)
        .padding(.bottom, ScopySpacing.xs)
        .background(isCollapsible && isHovered ? ScopyColors.hover.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsible {
                onToggle?()
            }
        }
        .onHover { hovering in
            if isCollapsible && !isScrolling {
                isHovered = hovering
            }
        }
        .onChange(of: isScrolling) { _, newValue in
            if newValue && isHovered {
                isHovered = false
            }
        }
        // The List raises every row to its row estimate; keep the title next to its rows.
        .frame(minHeight: ScopySize.Height.listRowEstimate, alignment: .bottom)
    }
}
