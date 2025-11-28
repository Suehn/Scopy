import SwiftUI

/// Capsule 风格的轻量过滤按钮
struct CapsuleFilterButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, ScopySpacing.sm)
            .padding(.vertical, ScopySpacing.xs)
            .background(
                Capsule().fill(isActive ? ScopyColors.selection : ScopyColors.secondaryBackground)
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? ScopyColors.selectionBorder : ScopyColors.separator.opacity(ScopySize.Opacity.medium), lineWidth: ScopySize.Stroke.normal)
            )
            .foregroundStyle(isActive ? Color.accentColor : ScopyColors.mutedText)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 轻量 Tag，用于显示搜索模式或状态
struct InfoTag: View {
    let text: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: ScopySpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .font(ScopyTypography.caption)
        }
        .padding(.horizontal, ScopySpacing.sm)
        .padding(.vertical, ScopySpacing.xxs)
        .background(
            Capsule().fill(ScopyColors.selection)
        )
        .foregroundStyle(Color.accentColor)
    }
}

// MARK: - v0.10.3 新增组件

/// 通用按钮组件 - 支持 disabled 状态和多种样式
struct ScopyButton: View {
    let title: String
    let icon: String?
    let style: ScopyButtonStyle
    let isDisabled: Bool
    let action: () -> Void

    enum ScopyButtonStyle {
        case primary
        case secondary
        case destructive
    }

    init(
        _ title: String,
        icon: String? = nil,
        style: ScopyButtonStyle = .secondary,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.isDisabled = isDisabled
        self.action = action
    }

    private var backgroundColor: Color {
        if isDisabled { return ScopyColors.secondaryBackground }
        switch style {
        case .primary: return Color.accentColor
        case .secondary: return ScopyColors.secondaryBackground
        case .destructive: return Color.red.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        if isDisabled { return ScopyColors.tertiaryText }
        switch style {
        case .primary: return .white
        case .secondary: return ScopyColors.text
        case .destructive: return .red
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ScopySpacing.xs) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(ScopyTypography.body)
            .padding(.horizontal, ScopySpacing.md)
            .padding(.vertical, ScopySpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: ScopySize.Corner.md, style: .continuous)
                    .fill(backgroundColor)
            )
            .foregroundStyle(foregroundColor)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
    }
}

/// 卡片容器组件
struct ScopyCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(ScopySpacing.md)
            .background(
                RoundedRectangle(cornerRadius: ScopySize.Corner.xl, style: .continuous)
                    .fill(ScopyColors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScopySize.Corner.xl, style: .continuous)
                    .stroke(ScopyColors.border.opacity(ScopySize.Opacity.medium), lineWidth: ScopySize.Stroke.thin)
            )
    }
}

/// 徽章组件 - 用于显示数量或状态
struct ScopyBadge: View {
    let text: String
    let style: BadgeStyle

    enum BadgeStyle {
        case `default`
        case accent
        case warning
        case success
    }

    init(_ text: String, style: BadgeStyle = .default) {
        self.text = text
        self.style = style
    }

    private var backgroundColor: Color {
        switch style {
        case .default: return ScopyColors.secondaryBackground
        case .accent: return Color.accentColor.opacity(0.15)
        case .warning: return Color.orange.opacity(0.15)
        case .success: return Color.green.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .default: return ScopyColors.mutedText
        case .accent: return Color.accentColor
        case .warning: return .orange
        case .success: return .green
        }
    }

    var body: some View {
        Text(text)
            .font(ScopyTypography.caption)
            .padding(.horizontal, ScopySpacing.sm)
            .padding(.vertical, ScopySpacing.xxs)
            .background(
                Capsule().fill(backgroundColor)
            )
            .foregroundStyle(foregroundColor)
    }
}

