import Foundation
import ScopyKit

/// The ChatGPT layout scale the hover preview shows: the preview-local override chosen from the
/// popover's scale control when one is stored, else the Settings value. The pipeline renders at
/// this scale so the first document is the displayed one.
enum MarkdownPreviewLayoutScalePreference {
    static let userDefaultsKey = "ScopyMarkdownPreviewLayoutScalePercent"

    static func active(settings: SettingsDTO) -> MarkdownChatGPTLayoutScalePercent {
        if UserDefaults.standard.object(forKey: userDefaultsKey) != nil {
            return MarkdownChatGPTLayoutScalePercent(
                settingsValue: UserDefaults.standard.integer(forKey: userDefaultsKey)
            )
        }
        return MarkdownChatGPTLayoutScalePercent(settingsValue: settings.markdownChatGPTLayoutScalePercent)
    }
}
