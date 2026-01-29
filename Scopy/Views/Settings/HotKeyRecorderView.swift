import SwiftUI
import Carbon.HIToolbox
import ScopyKit

struct HotKeyRecorderView: View {
    @Environment(SettingsViewModel.self) private var settingsViewModel

    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32

    let unregisterHotKeyHandler: (() -> Void)?
    let applyHotKeyHandler: ((UInt32, UInt32) -> Void)?

    @StateObject private var recorder = HotKeyRecorder()
    @State private var applyErrorMessage: String?

    var body: some View {
        Button(action: toggleRecording) {
            Text(recorder.isRecording ? "按键录制中…" : formatHotKey(keyCode: keyCode, modifiers: modifiers))
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(recorder.isRecording ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(recorder.isRecording ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onAppear {
            recorder.unregisterHotKeyHandler = unregisterHotKeyHandler
            recorder.applyHotKeyHandler = applyHotKeyHandler

            recorder.onRecorded = { newKeyCode, newModifiers in
                keyCode = newKeyCode
                modifiers = newModifiers
                Task { @MainActor in
                    await applyHotKeyAndSyncFromPersistedSettings(
                        expectedKeyCode: newKeyCode,
                        expectedModifiers: newModifiers
                    )
                }
            }
        }
        .onDisappear {
            recorder.stopRecording(restorePrevious: true)
        }
        .alert(
            "快捷键不可用",
            isPresented: Binding(
                get: { applyErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { applyErrorMessage = nil }
                }
            )
        ) {
            Button("好") { applyErrorMessage = nil }
        } message: {
            Text(applyErrorMessage ?? "")
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording(restorePrevious: true)
        } else {
            recorder.startRecording(currentKeyCode: keyCode, currentModifiers: modifiers)
        }
    }

    @MainActor
    private func applyHotKeyAndSyncFromPersistedSettings(expectedKeyCode: UInt32, expectedModifiers: UInt32) async {
        let store = SettingsStore.shared
        let initial = await store.load()
        let initialKeyCode = initial.hotkeyKeyCode
        let initialModifiers = initial.hotkeyModifiers

        applyHotKeyHandler?(expectedKeyCode, expectedModifiers)

        if initialKeyCode == expectedKeyCode, initialModifiers == expectedModifiers {
            return
        }

        if await waitForPersistedHotkey(
            store: store,
            expectedKeyCode: expectedKeyCode,
            expectedModifiers: expectedModifiers,
            timeout: 1.5
        ) {
            await settingsViewModel.loadSettings()
            return
        }

        // Either the requested hotkey was rejected and reverted, or we timed out waiting for persistence.
        await settingsViewModel.loadSettings()
        let persisted = settingsViewModel.settings

        guard persisted.hotkeyKeyCode != expectedKeyCode || persisted.hotkeyModifiers != expectedModifiers else {
            return
        }

        keyCode = persisted.hotkeyKeyCode
        modifiers = persisted.hotkeyModifiers
        applyErrorMessage = "该快捷键可能已被系统或其他应用占用，已恢复为 \(formatHotKey(keyCode: keyCode, modifiers: modifiers))"
    }

    @MainActor
    private func waitForPersistedHotkey(
        store: SettingsStore,
        expectedKeyCode: UInt32,
        expectedModifiers: UInt32,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + max(0, timeout)
        while CFAbsoluteTimeGetCurrent() < deadline {
            let current = await store.load()
            if current.hotkeyKeyCode == expectedKeyCode, current.hotkeyModifiers == expectedModifiers {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func formatHotKey(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []

        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        parts.append(keyCharFromKeyCode(keyCode))
        return parts.joined()
    }

    private func keyCharFromKeyCode(_ keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓"
        ]
        return keyMap[keyCode] ?? "?"
    }
}
