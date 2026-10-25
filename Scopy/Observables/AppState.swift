import AppKit
import Foundation
import Observation
import ScopyKit

/// Who changed the selection; only keyboard navigation scrolls the list to follow it.
enum SelectionSource {
    case keyboard
    case mouse
    case programmatic
}

struct StartupFailure: Equatable {
    let message: String
    let diagnostics: String
    let occurredAt: Date
}

enum StartupPhase: Equatable {
    case idle
    case starting
    case running
    case startupFailed(StartupFailure)
}

/// Owns the clipboard service and the view models shared by the panel and settings.
@Observable
@MainActor
final class AppState {
    // MARK: - Shared instance

    static let shared = AppState()

    // MARK: - Properties

    @ObservationIgnored let service: ClipboardServiceProtocol
    @ObservationIgnored let settingsViewModel: SettingsViewModel
    @ObservationIgnored let historyViewModel: HistoryViewModel

    @ObservationIgnored var closePanelHandler: (() -> Void)? {
        didSet { historyViewModel.closePanelHandler = closePanelHandler }
    }
    @ObservationIgnored var pasteAfterCopyHandler: (() -> Void)? {
        didSet { historyViewModel.pasteAfterCopyHandler = pasteAfterCopyHandler }
    }
    @ObservationIgnored var openSettingsHandler: (() -> Void)?

    @ObservationIgnored var applyHotKeyHandler: (@MainActor (UInt32, UInt32) async -> Bool)?
    @ObservationIgnored var beginHotKeyRecordingHandler: (@MainActor () -> HotKeyRecordingSession?)?

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private let serviceEnvironmentOptions: ServiceEnvironmentOptions
    @ObservationIgnored private var lastAppliedSettings: SettingsDTO?

    var startupPhase: StartupPhase = .idle

    private struct ServiceEnvironmentOptions {
        let databasePath: String?
        let monitorPasteboardName: String?
        let monitorPollingInterval: TimeInterval?

        static func load() -> ServiceEnvironmentOptions {
            let env = ProcessInfo.processInfo.environment
            let dbPath = normalizedString(env["SCOPY_SERVICE_DB_PATH"])
            let pasteboard = normalizedString(env["SCOPY_SERVICE_MONITOR_PASTEBOARD"])
            let interval = resolvePollingInterval(env: env)
            return ServiceEnvironmentOptions(
                databasePath: dbPath,
                monitorPasteboardName: pasteboard,
                monitorPollingInterval: interval
            )
        }

        var debugSummary: String {
            let database = databasePath ?? "<default>"
            let pasteboard = monitorPasteboardName ?? NSPasteboard.general.name.rawValue
            let interval = monitorPollingInterval.map { String(format: "%.3fs", $0) } ?? "<default>"
            return """
            databasePath: \(database)
            monitorPasteboardName: \(pasteboard)
            monitorPollingInterval: \(interval)
            """
        }

        private static func resolvePollingInterval(env: [String: String]) -> TimeInterval? {
            if let seconds = parseDouble(env["SCOPY_SERVICE_MONITOR_INTERVAL_SEC"]) {
                return max(0.01, seconds)
            }
            if let millis = parseDouble(env["SCOPY_SERVICE_MONITOR_INTERVAL_MS"]) {
                return max(0.01, millis / 1000.0)
            }
            return nil
        }

        private static func normalizedString(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func parseDouble(_ value: String?) -> Double? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Double(trimmed)
        }
    }

    private static let useMockService: Bool = {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return shouldUseMockService(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild
        )
    }()

    /// The mock exists only in Debug builds. Debug UI-test launches use it unless `USE_MOCK_SERVICE=0`;
    /// ordinary Debug launches use the real service unless `USE_MOCK_SERVICE=1`. Release never uses it.
    static func shouldUseMockService(
        arguments: [String],
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        guard isDebugBuild else { return false }
        if arguments.contains("--uitesting") {
            return environment["USE_MOCK_SERVICE"] != "0"
        }
        return isDebugBuild && environment["USE_MOCK_SERVICE"] == "1"
    }

    private init(service: ClipboardServiceProtocol? = nil) {
        let resolvedService: ClipboardServiceProtocol
        let envOptions = ServiceEnvironmentOptions.load()
        self.serviceEnvironmentOptions = envOptions
        if let service {
            resolvedService = service
            ScopyLog.app.info("Using injected Clipboard Service")
        } else if Self.useMockService {
            #if DEBUG
            resolvedService = MockClipboardService()
            ScopyLog.app.info("Using Mock Clipboard Service")
            #else
            fatalError("The mock clipboard service is compiled only into Debug builds")
            #endif
        } else {
            resolvedService = ClipboardServiceFactory.create(
                databasePath: envOptions.databasePath,
                monitorPasteboardName: envOptions.monitorPasteboardName,
                monitorPollingInterval: envOptions.monitorPollingInterval
            )
            ScopyLog.app.info("Using Real Clipboard Service")
        }

        self.service = resolvedService
        let settingsViewModel = SettingsViewModel(service: resolvedService)
        self.settingsViewModel = settingsViewModel
        self.historyViewModel = HistoryViewModel(service: resolvedService, settingsViewModel: settingsViewModel)
    }

    // MARK: - Lifecycle

    func start() async {
        if let stopTask {
            await stopTask.value
            return
        }
        if let startTask {
            await startTask.value
            return
        }
        guard startupPhase != .running else { return }
        startupPhase = .starting
        let task = Task { @MainActor in
            defer { startTask = nil }
            await startService()
        }
        startTask = task
        await task.value
    }

    private func startService() async {
        do {
            try await service.start()
            // A service that started while stop was requested still needs its event consumer
            // while the backend drains; cancellation only skips the initial UI loads.
            startEventListener()
            guard !Task.isCancelled else { return }
            ScopyLog.app.info("Clipboard Service started")
        } catch {
            guard !Task.isCancelled else { return }
            ScopyLog.app.error("Failed to start Clipboard Service: \(error.localizedDescription, privacy: .private)")
            await service.stopAndWait()
            guard !Task.isCancelled else { return }
            startupPhase = .startupFailed(makeStartupFailure(error: error))
            return
        }

        await refreshSettings(applyHotKey: false)
        guard !Task.isCancelled else { return }

        await historyViewModel.loadRecentApps()
        guard !Task.isCancelled else { return }
        await historyViewModel.load()
        guard !Task.isCancelled else { return }
        startupPhase = .running
    }

    func copyStartupDiagnosticsToPasteboard() {
        guard case .startupFailed(let failure) = startupPhase else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(failure.diagnostics, forType: .string)
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let startup = startTask
        startup?.cancel()
        let task = Task { @MainActor in
            defer { stopTask = nil }
            // A startup already inside the backend must settle before shutdown owns the service.
            await startup?.value
            // The bounded backend event queue needs its consumer until producers finish.
            await service.stopAndWait()
            let events = eventTask
            events?.cancel()
            historyViewModel.stop()
            await events?.value
            eventTask = nil
            startupPhase = .idle
        }
        stopTask = task
        await task.value
    }

    func stopForTermination() async -> Bool {
        guard await historyViewModel.prepareForTermination() else { return false }
        await stop()
        return true
    }

    // MARK: - Events

    private func startEventListener() {
        // Subscribe before returning so events emitted right after start() are not missed.
        let events = service.eventStream
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                guard !Task.isCancelled else { break }
                await self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem, .itemUpdated, .itemContentUpdated, .thumbnailUpdated, .itemDeleted, .itemsRemoved, .itemPinned, .itemUnpinned, .itemsCleared, .captureReadBlocked:
            await historyViewModel.handleEvent(event)
        case .settingsChanged:
            let patch = await refreshSettings(applyHotKey: true)
            if patch.affectsHistoryReload {
                await historyViewModel.load()
            }
        }
    }

    @discardableResult
    private func refreshSettings(applyHotKey: Bool) async -> SettingsPatch {
        let previousSettings = lastAppliedSettings ?? settingsViewModel.settings
        await settingsViewModel.loadSettings()
        let settings = settingsViewModel.settings
        let patch = SettingsPatch.from(baseline: previousSettings, draft: settings)
        lastAppliedSettings = settings
        historyViewModel.applySettings(settings)
        if applyHotKey {
            await applyHotKeyIfNeeded(settings: settings)
        }
        return patch
    }

    private func applyHotKeyIfNeeded(settings: SettingsDTO) async {
        if let handler = applyHotKeyHandler {
            _ = await handler(settings.hotkeyKeyCode, settings.hotkeyModifiers)
        } else {
            ScopyLog.app.warning("settingsChanged: applyHotKeyHandler not registered, hotkey may be out of sync")
        }
    }

    private func makeStartupFailure(error: Error) -> StartupFailure {
        let serviceName = String(describing: type(of: service))
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let diagnostics = """
        Scopy startup failed
        timestamp: \(timestamp)
        service: \(serviceName)
        error: \(error.localizedDescription)
        \(serviceEnvironmentOptions.debugSummary)
        """

        return StartupFailure(
            message: error.localizedDescription,
            diagnostics: diagnostics,
            occurredAt: Date()
        )
    }
}

// MARK: - Testing Support

#if DEBUG
extension AppState {
    static func forTesting(
        service: ClipboardServiceProtocol,
        historyTiming: HistoryViewModel.Timing = .tests
    ) -> AppState {
        let state = AppState(service: service)
        state.historyViewModel.configureTiming(historyTiming)
        return state
    }
}
#endif
