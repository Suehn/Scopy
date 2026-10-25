import Foundation

/// One suspension of the global shortcut while the settings window records its replacement.
/// AppDelegate decides whether the session is still current when its completion is applied.
@MainActor
struct HotKeyRecordingSession {
    enum Completion: Sendable {
        case cancel
        case shortcut(keyCode: UInt32, modifiers: UInt32)
    }

    let id: UUID
    let finish: @MainActor (Completion) async -> Bool
}
