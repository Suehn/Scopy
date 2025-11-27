import AppKit
import Foundation
import Observation

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

    /// 延迟初始化的单例，保持向后兼容
    private static var _shared: AppState?
    static var shared: AppState {
        if _shared == nil {
            _shared = AppState()
        }
        return _shared!
    }

    /// 工厂方法 - 创建带指定服务的实例（用于测试和依赖注入）
    static func create(service: ClipboardServiceProtocol) -> AppState {
        return AppState(service: service)
    }

    /// 重置单例（仅用于测试）
    static func resetShared() {
        _shared = nil
    }

    // MARK: - Properties

    // 后端服务（通过协议访问）
    var service: ClipboardServiceProtocol

    // UI 状态
    var items: [ClipboardItemDTO] = []
    var pinnedItems: [ClipboardItemDTO] { items.filter { $0.isPinned } }
    var unpinnedItems: [ClipboardItemDTO] { items.filter { !$0.isPinned } }

    var searchQuery: String = ""
    var searchMode: SearchMode = .fuzzy
    var isLoading: Bool = false
    var selectedID: UUID?

    // 过滤状态 (v0.9)
    var appFilter: String? = nil
    var typeFilter: ClipboardItemType? = nil
    var recentApps: [String] = []

    /// 是否有活跃的过滤条件（搜索词、app过滤、类型过滤）
    var hasActiveFilters: Bool {
        !searchQuery.isEmpty || appFilter != nil || typeFilter != nil
    }

    /// 选中来源 - 控制是否触发滚动
    var lastSelectionSource: SelectionSource = .programmatic

    // 滚动状态 (v0.9.3 - 快速滚动时禁用悬停高亮)
    var isScrolling: Bool = false
    private var scrollEndTimer: Timer?

    // 分页状态
    var canLoadMore: Bool = false
    var loadedCount: Int = 0
    var totalCount: Int = 0

    // 存储统计
    var storageStats: (itemCount: Int, sizeBytes: Int) = (0, 0)
    var storageSizeText: String {
        let kb = Double(storageStats.sizeBytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        } else {
            return String(format: "%.1f MB", kb / 1024)
        }
    }

    // UI 回调（用于 AppDelegate 通信，支持测试解耦）
    var closePanelHandler: (() -> Void)?
    var openSettingsHandler: (() -> Void)?

    // 快捷键回调（用于解耦 SettingsView 与 AppDelegate）
    var applyHotKeyHandler: ((UInt32, UInt32) -> Void)?
    var unregisterHotKeyHandler: (() -> Void)?

    // 事件监听任务
    private var eventTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    // 配置：是否使用真实服务
    private static let useMockService: Bool = {
        #if DEBUG
        // 在 Debug 模式下，检查环境变量来决定
        return ProcessInfo.processInfo.environment["USE_MOCK_SERVICE"] != "0"
        #else
        // Release 模式使用真实服务
        return false
        #endif
    }()

    /// 初始化 - 可接受注入的服务（用于测试），默认根据配置选择
    private init(service: ClipboardServiceProtocol? = nil) {
        if let service = service {
            self.service = service
            print("📋 Using injected Clipboard Service")
        } else if Self.useMockService {
            self.service = MockClipboardService()
            print("📋 Using Mock Clipboard Service")
        } else {
            self.service = RealClipboardService()
            print("📋 Using Real Clipboard Service")
        }
    }

    /// 启动应用服务
    func start() async {
        // 通过协议方法启动服务（RealClipboardService 会初始化数据库和监控，MockClipboardService 为空实现）
        do {
            try await service.start()
            print("✅ Clipboard Service started")
        } catch {
            print("❌ Failed to start Clipboard Service: \(error)")
            // 降级到 Mock 服务
            service = MockClipboardService()
            print("⚠️ Falling back to Mock Clipboard Service")
        }

        // 监听事件流
        startEventListener()

        // 加载设置
        await loadSettings()

        // 加载最近使用的 app 列表
        await loadRecentApps()

        // 初始加载
        await load()
    }

    /// 停止应用服务
    func stop() {
        eventTask?.cancel()
        eventTask = nil

        // 通过协议方法停止服务
        service.stop()
    }

    // MARK: - Settings Management

    var settings: SettingsDTO = .default

    func loadSettings() async {
        do {
            settings = try await service.getSettings()
        } catch {
            print("Failed to load settings: \(error)")
        }
    }

    /// 加载最近使用的 app 列表（用于过滤菜单）
    func loadRecentApps() async {
        do {
            recentApps = try await service.getRecentApps(limit: 10)
        } catch {
            print("Failed to load recent apps: \(error)")
        }
    }

    func updateSettings(_ newSettings: SettingsDTO) async {
        do {
            try await service.updateSettings(newSettings)
            settings = newSettings
        } catch {
            print("Failed to update settings: \(error)")
        }
    }

    /// 监听剪贴板事件
    func startEventListener() {
        eventTask = Task { [weak self] in
            guard let self = self else { return }
            for await event in self.service.eventStream {
                // 使用 Task.detached 避免阻塞主循环
                Task { @MainActor in
                    await self.handleEvent(event)
                }
            }
        }
    }

    private func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem(let item):
            // 新项目或重复项目：移除旧位置，插入到顶部
            let wasExisting = items.contains(where: { $0.id == item.id })
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            // 只有真正新增时才增加 totalCount
            if !wasExisting {
                totalCount += 1
            }
            // 如果是新 app，刷新 app 列表
            if let bundleID = item.appBundleID, !recentApps.contains(bundleID) {
                Task { await loadRecentApps() }
            }
        case .itemUpdated(let item):
            // 更新的项目：移除旧位置，插入到顶部（用于复制置顶）
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
        case .itemDeleted(let id):
            items.removeAll { $0.id == id }
            totalCount -= 1
        case .itemPinned, .itemUnpinned:
            // 刷新以获取最新状态
            await load()
        case .settingsChanged:
            // 设置变化时刷新，并通过回调重新应用全局快捷键（解耦 AppDelegate）
            applyHotKeyHandler?(settings.hotkeyKeyCode, settings.hotkeyModifiers)
            await load()
        }
    }

    /// 初始加载
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let startTime = CFAbsoluteTimeGetCurrent()

            items = try await service.fetchRecent(limit: 50, offset: 0)
            loadedCount = items.count
            let stats = try await service.getStorageStats()
            totalCount = stats.itemCount
            storageStats = stats
            canLoadMore = loadedCount < totalCount

            // 记录首屏加载性能
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            await PerformanceMetrics.shared.recordLoadLatency(elapsedMs)
        } catch {
            print("Failed to load items: \(error)")
        }
    }

    /// 加载更多（懒加载）- 符合 v0.md 的分页设计
    /// 滚动事件处理 - 快速滚动时禁用悬停高亮
    func onScroll() {
        isScrolling = true
        scrollEndTimer?.invalidate()
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isScrolling = false
            }
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if hasActiveFilters {
                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    appFilter: appFilter,
                    typeFilter: typeFilter,
                    limit: 50,
                    offset: loadedCount
                )
                let result = try await service.search(query: request)
                items.append(contentsOf: result.items)
                loadedCount = items.count
                totalCount = result.total
                canLoadMore = result.hasMore
            } else {
                let moreItems = try await service.fetchRecent(limit: 100, offset: loadedCount)
                items.append(contentsOf: moreItems)
                loadedCount = items.count
                canLoadMore = loadedCount < totalCount
            }
        } catch {
            print("Failed to load more: \(error)")
        }
    }

    /// 搜索（带防抖）- 符合 v0.md 的 150-200ms 防抖设计
    func search() {
        searchTask?.cancel()

        // 如果没有搜索词且没有过滤条件，直接加载全部
        if searchQuery.isEmpty && appFilter == nil && typeFilter == nil {
            Task { await load() }
            return
        }

        searchTask = Task {
            // 防抖 150ms
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            isLoading = true
            defer { isLoading = false }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()

                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    appFilter: appFilter,
                    typeFilter: typeFilter,
                    limit: 50,
                    offset: 0
                )
                let result = try await service.search(query: request)
                items = result.items
                totalCount = result.total
                loadedCount = result.items.count
                canLoadMore = result.hasMore

                // 记录搜索性能
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await PerformanceMetrics.shared.recordSearchLatency(elapsedMs)
            } catch {
                print("Search failed: \(error)")
            }
        }
    }

    /// 选择并复制
    func select(_ item: ClipboardItemDTO) async {
        do {
            try await service.copyToClipboard(itemID: item.id)
            closePanelHandler?()
        } catch {
            print("Copy failed: \(error)")
        }
    }

    /// 切换固定状态
    func togglePin(_ item: ClipboardItemDTO) async {
        do {
            if item.isPinned {
                try await service.unpin(itemID: item.id)
            } else {
                try await service.pin(itemID: item.id)
            }
            await load()  // 刷新列表
        } catch {
            print("Pin toggle failed: \(error)")
        }
    }

    /// 删除项目
    func delete(_ item: ClipboardItemDTO) async {
        do {
            try await service.delete(itemID: item.id)
            items.removeAll { $0.id == item.id }
            totalCount -= 1
        } catch {
            print("Delete failed: \(error)")
        }
    }

    /// 清空历史
    func clearAll() async {
        do {
            try await service.clearAll()
            await load()
        } catch {
            print("Clear failed: \(error)")
        }
    }

    // MARK: - 键盘导航

    func highlightNext() {
        guard !items.isEmpty else { return }
        lastSelectionSource = .keyboard
        if let currentID = selectedID,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }),
           currentIndex < items.count - 1 {
            selectedID = items[currentIndex + 1].id
        } else {
            selectedID = items.first?.id
        }
    }

    func highlightPrevious() {
        guard !items.isEmpty else { return }
        lastSelectionSource = .keyboard
        if let currentID = selectedID,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }),
           currentIndex > 0 {
            selectedID = items[currentIndex - 1].id
        } else {
            selectedID = items.last?.id
        }
    }

    /// 删除当前选中项
    func deleteSelectedItem() async {
        guard let id = selectedID else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        // 确定下一个要选中的项
        let nextID: UUID?
        if index < items.count - 1 {
            nextID = items[index + 1].id
        } else if index > 0 {
            nextID = items[index - 1].id
        } else {
            nextID = nil
        }

        // 删除当前项
        if let item = items.first(where: { $0.id == id }) {
            await delete(item)
        }

        // 选中下一项
        selectedID = nextID
        lastSelectionSource = .programmatic
    }

    func selectCurrent() async {
        if let selectedID,
           let item = items.first(where: { $0.id == selectedID }) {
            await select(item)
        }
    }
}

// MARK: - Testing Support

extension AppState {
    /// Create an AppState with a specific service (for testing)
    /// 使用 create(service:) 工厂方法，确保服务在初始化时注入
    static func forTesting(service: ClipboardServiceProtocol) -> AppState {
        return create(service: service)
    }
}
