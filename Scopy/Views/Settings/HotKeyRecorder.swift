import Foundation
import Carbon.HIToolbox
import AppKit

@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published var isRecording = false

    var onRecorded: ((UInt32, UInt32) -> Void)?
    var unregisterHotKeyHandler: (() -> Void)?
    var applyHotKeyHandler: ((UInt32, UInt32) -> Void)?

    private var eventMonitor: Any?
    private var globalEventMonitor: Any?
    private var previousHotKey: (keyCode: UInt32, modifiers: UInt32)?
    private var didRecordNewHotKey = false

    func startRecording(currentKeyCode: UInt32, currentModifiers: UInt32) {
        guard !isRecording else { return }

        isRecording = true
        didRecordNewHotKey = false
        previousHotKey = (currentKeyCode, currentModifiers)

        unregisterHotKeyHandler?()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event)
            }
        }
    }

    func stopRecording(restorePrevious: Bool) {
        guard isRecording else { return }

        isRecording = false

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        eventMonitor = nil
        globalEventMonitor = nil

        if restorePrevious, let previousHotKey, !didRecordNewHotKey {
            applyHotKeyHandler?(previousHotKey.keyCode, previousHotKey.modifiers)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }

        if event.type == .keyDown, event.keyCode == 53 { // Esc
            stopRecording(restorePrevious: true)
            return
        }

        if event.type == .keyDown {
            let keyCode = UInt32(event.keyCode)
            let modifiers = carbonModifiers(from: event.modifierFlags)

            if modifiers == 0 {
                return
            }

            didRecordNewHotKey = true
            onRecorded?(keyCode, modifiers)
            stopRecording(restorePrevious: false)
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }
}
