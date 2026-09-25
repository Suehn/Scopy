import Foundation

/// One sample of the page-side layout watcher.
struct ExportLayoutSample: Equatable {
    let frames: Int
    let stableFrames: Int
    let height: CGFloat
    let liveHeight: CGFloat
    let fonts: String
    let renderReady: Bool
    let renderFailed: Bool
    let renderErrorReason: String?
}

/// A sample the watcher pushed (or returned) for one layout phase; `event` names why it was sent.
struct ExportLayoutMessage: Equatable {
    let phase: Int
    let event: String
    let sample: ExportLayoutSample

    init?(body: Any) {
        guard let object = body as? [String: Any],
              let phase = (object["phase"] as? NSNumber)?.intValue,
              let event = object["event"] as? String else { return nil }
        func number(_ key: String) -> CGFloat {
            (object[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        }
        let reason = (object["renderErrorReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phase = phase
        self.event = event
        sample = ExportLayoutSample(
            frames: Int(number("frames")),
            stableFrames: Int(number("stableFrames")),
            height: max(0, number("height")),
            liveHeight: max(0, number("live")),
            fonts: (object["fonts"] as? String) ?? "n/a",
            renderReady: (object["renderReady"] as? Bool) ?? false,
            renderFailed: (object["renderFailed"] as? Bool) ?? false,
            renderErrorReason: (reason?.isEmpty ?? true) ? nil : reason
        )
    }
}

/// Numbers each settle wait and keeps only the messages of the current one.
struct ExportLayoutPhases {
    private(set) var current = 0
    private(set) var latest: ExportLayoutMessage?

    mutating func begin() -> Int {
        current += 1
        latest = nil
        return current
    }

    /// Returns false and drops `message` when it was posted for an earlier phase.
    mutating func receive(_ message: ExportLayoutMessage) -> Bool {
        guard message.phase == current else { return false }
        latest = message
        return true
    }
}

@MainActor
final class ExportLayoutWaiter {
    let condition: (ExportLayoutMessage) -> Bool
    private var continuation: CheckedContinuation<ExportLayoutMessage?, Never>?

    init(condition: @escaping (ExportLayoutMessage) -> Bool, continuation: CheckedContinuation<ExportLayoutMessage?, Never>) {
        self.condition = condition
        self.continuation = continuation
    }

    func resume(_ message: ExportLayoutMessage?) {
        continuation?.resume(returning: message)
        continuation = nil
    }
}
