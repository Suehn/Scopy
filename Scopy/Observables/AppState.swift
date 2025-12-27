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

    private static let useMockService: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["USE_MOCK_SERVICE"] != "0"
        #else
        return false
        #endif
    }()

    private init(service: ClipboardServiceProtocol? = nil) {
        let resolvedService: ClipboardServiceProtocol
        if let service {
            resolvedService = service
            ScopyLog.app.info("Using injected Clipboard Service")
        } else if Self.useMockService {
            resolvedService = ClipboardServiceFactory.create(useMock: true)
            ScopyLog.app.info("Using Mock Clipboard Service")
        } else {
            resolvedService = ClipboardServiceFactory.create(useMock: false)
            ScopyLog.app.info("Using Real Clipboard Service")
        }

        self.service = resolvedService
        let settingsViewModel = SettingsViewModel(service: resolvedService)
        self.settingsViewModel = settingsViewModel
        self.historyViewModel = HistoryViewModel(service: resolvedService, settingsViewModel: settingsViewModel)
    }

    // MARK: - Lifecycle

    func start() async {
        do {
            try await service.start()
            ScopyLog.app.info("Clipboard Service started")
        } catch {
            ScopyLog.app.error("Failed to start Clipboard Service: \(error.localizedDescription, privacy: .private)")
            await service.stopAndWait()

            let fallback = ClipboardServiceFactory.create(useMock: true)
            service = fallback
            settingsViewModel.updateService(fallback)
            historyViewModel.updateService(fallback)

            do {
                try await fallback.start()
                ScopyLog.app.warning("Falling back to Mock Clipboard Service (started)")
            } catch {
                ScopyLog.app.error("Mock service also failed to start: \(error.localizedDescription, privacy: .private)")
            }
        }

        startEventListener()

        await refreshSettings(applyHotKey: false)

        await historyViewModel.loadRecentApps()
        await historyViewModel.load()
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil

        historyViewModel.stop()
        service.stop()
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: SettingsDTO) async {
        await settingsViewModel.updateSettings(newSettings)
    }

    // MARK: - Events

    func startEventListener() {
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
            await refreshSettings(applyHotKey: true)
            await historyViewModel.load()
        }
    }

    private func refreshSettings(applyHotKey: Bool) async {
        await settingsViewModel.loadSettings()
        let settings = settingsViewModel.settings
        historyViewModel.applySettings(settings)
        if applyHotKey {
            applyHotKeyIfNeeded(settings: settings)
        }
    }

    private func applyHotKeyIfNeeded(settings: SettingsDTO) {
        if let handler = applyHotKeyHandler {
            handler(settings.hotkeyKeyCode, settings.hotkeyModifiers)
        } else {
            ScopyLog.app.warning("settingsChanged: applyHotKeyHandler not registered, hotkey may be out of sync")
        }
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

// MARK: - Compatibility (AppState API)

extension AppState {
    var items: [ClipboardItemDTO] {
        get { historyViewModel.items }
        set { historyViewModel.items = newValue }
    }

    var pinnedItems: [ClipboardItemDTO] { historyViewModel.pinnedItems }
    var unpinnedItems: [ClipboardItemDTO] { historyViewModel.unpinnedItems }

    var searchQuery: String {
        get { historyViewModel.searchQuery }
        set { historyViewModel.searchQuery = newValue }
    }

    var searchMode: SearchMode {
        get { historyViewModel.searchMode }
        set { historyViewModel.searchMode = newValue }
    }

    var isLoading: Bool {
        get { historyViewModel.isLoading }
        set { historyViewModel.isLoading = newValue }
    }

    var selectedID: UUID? {
        get { historyViewModel.selectedID }
        set { historyViewModel.selectedID = newValue }
    }

    var isPinnedCollapsed: Bool {
        get { historyViewModel.isPinnedCollapsed }
        set { historyViewModel.isPinnedCollapsed = newValue }
    }

    var appFilter: String? {
        get { historyViewModel.appFilter }
        set { historyViewModel.appFilter = newValue }
    }

    var typeFilter: ClipboardItemType? {
        get { historyViewModel.typeFilter }
        set { historyViewModel.typeFilter = newValue }
    }

    var typeFilters: Set<ClipboardItemType>? {
        get { historyViewModel.typeFilters }
        set { historyViewModel.typeFilters = newValue }
    }

    var recentApps: [String] {
        get { historyViewModel.recentApps }
        set { historyViewModel.recentApps = newValue }
    }

    var hasActiveFilters: Bool { historyViewModel.hasActiveFilters }

    var lastSelectionSource: SelectionSource {
        get { historyViewModel.lastSelectionSource }
        set { historyViewModel.lastSelectionSource = newValue }
    }

    var isScrolling: Bool {
        get { historyViewModel.isScrolling }
        set { historyViewModel.isScrolling = newValue }
    }

    var canLoadMore: Bool {
        get { historyViewModel.canLoadMore }
        set { historyViewModel.canLoadMore = newValue }
    }

    var loadedCount: Int {
        get { historyViewModel.loadedCount }
        set { historyViewModel.loadedCount = newValue }
    }

    var totalCount: Int {
        get { historyViewModel.totalCount }
        set { historyViewModel.totalCount = newValue }
    }

    var performanceSummary: PerformanceSummary? {
        get { historyViewModel.performanceSummary }
        set { historyViewModel.performanceSummary = newValue }
    }

    var settings: SettingsDTO {
        get { settingsViewModel.settings }
        set { settingsViewModel.settings = newValue }
    }

    var storageStats: (itemCount: Int, sizeBytes: Int) {
        get { settingsViewModel.storageStats }
        set { settingsViewModel.storageStats = newValue }
    }

    var diskSizeBytes: Int {
        get { settingsViewModel.diskSizeBytes }
        set { settingsViewModel.diskSizeBytes = newValue }
    }

    var storageSizeText: String { settingsViewModel.storageSizeText }

    func loadSettings() async {
        await settingsViewModel.loadSettings()
        historyViewModel.applySettings(settingsViewModel.settings)
    }

    func loadRecentApps() async {
        await historyViewModel.loadRecentApps()
    }

    func load() async {
        await historyViewModel.load()
    }

    func scrollDidStart() {
        historyViewModel.scrollDidStart()
    }

    func scrollDidEnd() {
        historyViewModel.scrollDidEnd()
    }

    func loadMore() async {
        await historyViewModel.loadMore()
    }

    func search() {
        historyViewModel.search()
    }

    func select(_ item: ClipboardItemDTO) async {
        await historyViewModel.select(item)
    }

    func togglePin(_ item: ClipboardItemDTO) async {
        await historyViewModel.togglePin(item)
    }

    func delete(_ item: ClipboardItemDTO) async {
        await historyViewModel.delete(item)
    }

    func clearAll() async {
        await historyViewModel.clearAll()
    }

    func highlightNext() {
        historyViewModel.highlightNext()
    }

    func highlightPrevious() {
        historyViewModel.highlightPrevious()
    }

    func deleteSelectedItem() async {
        await historyViewModel.deleteSelectedItem()
    }

    func selectCurrent() async {
        await historyViewModel.selectCurrent()
    }
}
