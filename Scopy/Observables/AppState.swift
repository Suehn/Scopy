import AppKit
import Foundation
import Observation
import ScopyKit

/// 选中来源 - 用于区分鼠标和键盘导航
enum SelectionSource {
    case keyboard   // 键盘导航：应该滚动到选中项
    case mouse      // 鼠标悬停：不应滚动
    case programmatic // 程序设置：不滚动
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

/// 应用状态 - 符合 v0.md 的 Observable 架构
@Observable
@MainActor
final class AppState {
    // MARK: - Singleton (兼容层)

    private static var _shared: AppState?
    static var shared: AppState {
        if _shared == nil {
            _shared = AppState()
        }
        return _shared!
    }

    static func create(service: ClipboardServiceProtocol) -> AppState {
        AppState(service: service)
    }

    static func resetShared() {
        _shared = nil
    }

    // MARK: - Properties

    @ObservationIgnored var service: ClipboardServiceProtocol
    @ObservationIgnored let settingsViewModel: SettingsViewModel
    @ObservationIgnored let historyViewModel: HistoryViewModel

    @ObservationIgnored var closePanelHandler: (() -> Void)? {
        didSet { historyViewModel.closePanelHandler = closePanelHandler }
    }
    @ObservationIgnored var openSettingsHandler: (() -> Void)?

    @ObservationIgnored var applyHotKeyHandler: ((UInt32, UInt32) -> Void)?
    @ObservationIgnored var unregisterHotKeyHandler: (() -> Void)?

    @ObservationIgnored private var eventTask: Task<Void, Never>?
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
        return ProcessInfo.processInfo.environment["USE_MOCK_SERVICE"] != "0"
        #else
        return false
        #endif
    }()

    private init(service: ClipboardServiceProtocol? = nil) {
        let resolvedService: ClipboardServiceProtocol
        let envOptions = ServiceEnvironmentOptions.load()
        self.serviceEnvironmentOptions = envOptions
        if let service {
            resolvedService = service
            ScopyLog.app.info("Using injected Clipboard Service")
        } else if Self.useMockService {
            resolvedService = ClipboardServiceFactory.create(useMock: true)
            ScopyLog.app.info("Using Mock Clipboard Service")
        } else {
            resolvedService = ClipboardServiceFactory.create(
                useMock: false,
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
        guard startupPhase != .running && startupPhase != .starting else { return }
        startupPhase = .starting

        do {
            try await service.start()
            ScopyLog.app.info("Clipboard Service started")
        } catch {
            ScopyLog.app.error("Failed to start Clipboard Service: \(error.localizedDescription, privacy: .private)")
            await service.stopAndWait()
            startupPhase = .startupFailed(makeStartupFailure(error: error))
            return
        }

        startEventListener()

        await refreshSettings(applyHotKey: false)

        await historyViewModel.loadRecentApps()
        await historyViewModel.load()
        startupPhase = .running
    }

    func copyStartupDiagnosticsToPasteboard() {
        guard case .startupFailed(let failure) = startupPhase else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(failure.diagnostics, forType: .string)
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil

        historyViewModel.stop()
        service.stop()
        startupPhase = .idle
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: SettingsDTO) async {
        await settingsViewModel.updateSettings(newSettings)
    }

    // MARK: - Events

    func startEventListener() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.service.eventStream {
                guard !Task.isCancelled else { break }
                await self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem, .itemUpdated, .itemContentUpdated, .thumbnailUpdated, .itemDeleted, .itemPinned, .itemUnpinned, .itemsCleared:
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
            applyHotKeyIfNeeded(settings: settings)
        }
        return patch
    }

    private func applyHotKeyIfNeeded(settings: SettingsDTO) {
        if let handler = applyHotKeyHandler {
            handler(settings.hotkeyKeyCode, settings.hotkeyModifiers)
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

extension AppState {
    static func forTesting(
        service: ClipboardServiceProtocol,
        historyTiming: HistoryViewModel.Timing = .tests
    ) -> AppState {
        let state = create(service: service)
        state.historyViewModel.configureTiming(historyTiming)
        return state
    }
}
