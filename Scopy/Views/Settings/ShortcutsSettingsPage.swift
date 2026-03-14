import SwiftUI
import ScopyKit

struct ShortcutsSettingsPage: View {
    @Binding var tempSettings: SettingsDTO
    let unregisterHotKeyHandler: (() -> Void)?
    let applyHotKeyHandler: ((UInt32, UInt32) -> Void)?

    var body: some View {
        SettingsPageContainer(page: .shortcuts) {
            SettingsSection(
                "快捷键",
                systemImage: "keyboard",
                footer: "点击录制新快捷键，按 ESC 取消。录制完成后会立即生效并持久化。"
            ) {
                SettingsCardRow {
                    LabeledContent("全局快捷键") {
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
