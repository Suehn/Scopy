import Foundation
import Carbon.HIToolbox
import AppKit

@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published private var session: HotKeyRecordingSession?
    @Published private(set) var isApplying = false

    var isRecording: Bool { session != nil }
    var beginRecording: (@MainActor () -> HotKeyRecordingSession?)?
    var onApplied: (@MainActor (Bool) async -> Void)?

    private var eventMonitor: Any?
    private var globalEventMonitor: Any?

    func startRecording() {
        guard !isRecording, !isApplying, let session = beginRecording?() else { return }
        self.session = session
        let sessionID = session.id

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event, sessionID: sessionID)
            return nil
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event, sessionID: sessionID)
            }
        }
    }

    func stopRecording() {
        guard let session = endRecording() else { return }
        Task { @MainActor in
            _ = await session.finish(.cancel)
        }
    }

    private func endRecording() -> HotKeyRecordingSession? {
        guard let session else { return nil }
        self.session = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        eventMonitor = nil
        globalEventMonitor = nil

        return session
    }

    private func handleKeyEvent(_ event: NSEvent, sessionID: UUID) {
        guard session?.id == sessionID else { return }

        if event.type == .keyDown, event.keyCode == 53 { // Esc
            stopRecording()
            return
        }

        if event.type == .keyDown {
            let keyCode = UInt32(event.keyCode)
            let modifiers = carbonModifiers(from: event.modifierFlags)

            if modifiers == 0 {
                return
            }

            guard let session = endRecording() else { return }
            isApplying = true
            Task { @MainActor [weak self] in
                let applied = await session.finish(.shortcut(keyCode: keyCode, modifiers: modifiers))
                guard let self else { return }
                await onApplied?(applied)
                isApplying = false
            }
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
