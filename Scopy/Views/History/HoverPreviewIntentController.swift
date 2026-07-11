import AppKit
import Foundation

/// Immutable envelope used only to carry MainActor teardown through a nonisolated
/// `deinit`. The controller consumes the envelope exactly once before `run()`.
private final class HoverPreviewIntentFinishHandler: @unchecked Sendable {
    private let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @MainActor
    func run() {
        handler()
    }
}

/// Owns the short-lived sampling task used only while the pointer crosses from a row to its popover.
/// It is deliberately not observable, so 60 Hz pointer sampling never invalidates SwiftUI views.
@MainActor
final class HoverPreviewIntentController {
    struct Dependencies {
        let cursorLocation: @MainActor () -> CGPoint
        let uptime: @MainActor () -> TimeInterval
        let sleep: @MainActor (UInt64) async throws -> Void

        @MainActor static let live = Dependencies(
            cursorLocation: { NSEvent.mouseLocation },
            uptime: { ProcessInfo.processInfo.systemUptime },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )
    }

    private let configuration: HoverPreviewIntentPolicy.Configuration
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?
    private var finishHandler: HoverPreviewIntentFinishHandler?
    private var generation: UInt64 = 0

    private(set) var isActive = false

    init(
        configuration: HoverPreviewIntentPolicy.Configuration = .default,
        dependencies: Dependencies? = nil
    ) {
        self.configuration = configuration
        self.dependencies = dependencies ?? .live
    }

    func start(
        exitPoint: CGPoint,
        targetFrame: @escaping @MainActor () -> CGRect?,
        shouldKeepAlive: @escaping @MainActor () -> Bool,
        onDismiss: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void = { }
    ) {
        cancel()
        generation &+= 1
        let currentGeneration = generation
        let configuration = configuration
        let dependencies = dependencies
        isActive = true
        finishHandler = HoverPreviewIntentFinishHandler(onFinish)

        task = Task { @MainActor [weak self] in
            var session = HoverPreviewIntentPolicy.Session(
                origin: exitPoint,
                targetFrame: targetFrame(),
                configuration: configuration
            )
            let startedAt = dependencies.uptime()
            var shouldDismiss = false

            while !Task.isCancelled {
                if shouldKeepAlive() {
                    break
                }

                let elapsed = max(0, dependencies.uptime() - startedAt)
                let decision = session.evaluate(
                    pointer: dependencies.cursorLocation(),
                    targetFrame: targetFrame(),
                    elapsed: elapsed
                )
                if case .dismiss = decision {
                    shouldDismiss = true
                    break
                }

                do {
                    try await dependencies.sleep(configuration.sampleIntervalNanoseconds)
                } catch {
                    break
                }
            }

            guard let self, self.generation == currentGeneration else { return }
            self.task = nil
            self.isActive = false
            let finishHandler = self.finishHandler
            self.finishHandler = nil
            if shouldDismiss, !shouldKeepAlive() {
                onDismiss()
            }
            finishHandler?.run()
        }
    }

    func cancel() {
        generation &+= 1
        let finishHandler = self.finishHandler
        self.finishHandler = nil
        task?.cancel()
        task = nil
        let wasActive = isActive
        isActive = false
        if wasActive {
            finishHandler?.run()
        }
    }

    deinit {
        task?.cancel()
        guard let finishHandler else { return }
        DispatchQueue.main.async {
            finishHandler.run()
        }
    }
}
