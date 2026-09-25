import SwiftUI
import AppKit

/// View colors, derived from system dynamic colors so they follow appearance changes.
enum ScopyColors {
    // MARK: - Window & Backgrounds
    static let background = Color(nsColor: .windowBackgroundColor)
    static let secondaryBackground = Color(nsColor: .controlBackgroundColor)
    
    // Spotlight/Raycast style: slightly translucent, dark/vibrant
    static let cardBackground = Color(nsColor: .windowBackgroundColor.withAlphaComponent(0.6))
    
    // MARK: - Separators & Borders
    static let separator = Color(nsColor: .separatorColor)
    static let border = Color(nsColor: .gridColor)
    
    // MARK: - Interaction
    // The selected row (Enter target) is stronger than a hovered row.
    private static let highlightBase = Color(nsColor: .selectedContentBackgroundColor)
    static let selection = highlightBase.opacity(0.25)
    static let hover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    static let selectionBorder = highlightBase.opacity(0.4)
    static let searchMatch = Color(nsColor: .findHighlightColor)
    
    // MARK: - Text
    static let text = Color.primary
    static let mutedText = Color.secondary
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    
    // MARK: - Status
    static let warning = Color.orange
    static let success = Color.green
    static let accent = Color.accentColor
}
