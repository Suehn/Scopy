import SwiftUI
import ScopyKit

struct ShortcutsSettingsPage: View {
    @Binding var tempSettings: SettingsDTO
    let unregisterHotKeyHandler: (() -> Void)?
    let applyHotKeyHandler: ((UInt32, UInt32) -> Void)?

    var body: some View {
        SettingsPageContainer(page: .shortcuts) {
            SettingsSection(
                "Shortcuts",
                systemImage: "keyboard",
                footer: "Click to record a new shortcut; press Esc to cancel. A recorded shortcut takes effect and is saved immediately."
            ) {
                SettingsCardRow {
                    LabeledContent("Global hotkey") {
                        HotKeyRecorderView(
                            keyCode: $tempSettings.hotkeyKeyCode,
                            modifiers: $tempSettings.hotkeyModifiers,
                            unregisterHotKeyHandler: unregisterHotKeyHandler,
                            applyHotKeyHandler: applyHotKeyHandler
                        )
                    }
                }
            }
        }
    }
}
