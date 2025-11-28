import SwiftUI
import AppKit

/// 设计系统颜色 - 仅用于前端视图，保持与系统动态颜色一致
enum ScopyColors {
    // MARK: - Window & Backgrounds
    static let background = Color(nsColor: .windowBackgroundColor)
    static let secondaryBackground = Color(nsColor: .controlBackgroundColor)
    
    // Spotlight/Raycast style: slightly translucent, dark/vibrant
    static let cardBackground = Color(nsColor: .windowBackgroundColor.withAlphaComponent(0.6))
    static let headerBackground = Color.clear // Header blends with window
    
    // MARK: - Separators & Borders
    static let separator = Color(nsColor: .separatorColor)
    static let border = Color(nsColor: .gridColor)
    
    // MARK: - Interaction
    // v0.10.3: 区分键盘选中和鼠标悬停
    private static let highlightBase = Color(nsColor: .selectedContentBackgroundColor)
    static let selection = highlightBase.opacity(0.25)  // 键盘选中：更明显的蓝色
    static let hover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)  // 鼠标悬停：淡灰色
    static let selectionBorder = highlightBase.opacity(0.4) // 键盘选中边框
    
    // MARK: - Text
    static let text = Color.primary
    static let mutedText = Color.secondary
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    
    // MARK: - Status
    static let warning = Color.orange
    static let success = Color.green
    static let accent = Color.accentColor
}
