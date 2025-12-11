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
    var items: [ClipboardItemDTO] = [] {
        didSet {
            invalidatePinnedCache()
        }
    }
    private var pinnedItemsCache: [ClipboardItemDTO]?
    private var unpinnedItemsCache: [ClipboardItemDTO]?

    /// v0.16.2: 手动失效缓存（用于 items 数组被修改而非重新赋值的情况）
    private func invalidatePinnedCache() {
        pinnedItemsCache = nil
        unpinnedItemsCache = nil
    }

    var pinnedItems: [ClipboardItemDTO] {
        if let cached = pinnedItemsCache { return cached }
        let result = items.filter { $0.isPinned }
        pinnedItemsCache = result
        return result
    }
    var unpinnedItems: [ClipboardItemDTO] {
        if let cached = unpinnedItemsCache { return cached }
        let result = items.filter { !$0.isPinned }
        unpinnedItemsCache = result
        return result
    }

    var searchQuery: String = ""
    var searchMode: SearchMode = SettingsDTO.default.defaultSearchMode
    var isLoading: Bool = false
    var selectedID: UUID?

    /// v0.16.2: Pinned 区域折叠状态
    var isPinnedCollapsed: Bool = false

    // 过滤状态 (v0.9)
    var appFilter: String? = nil
    var typeFilter: ClipboardItemType? = nil
    /// v0.22: 多类型过滤，用于 Rich Text (rtf + html)
    var typeFilters: Set<ClipboardItemType>? = nil
    var recentApps: [String] = []

    /// 是否有活跃的过滤条件（搜索词、app过滤、类型过滤）
    var hasActiveFilters: Bool {
        !searchQuery.isEmpty || appFilter != nil || typeFilter != nil || typeFilters != nil
    }

    /// 选中来源 - 控制是否触发滚动
    var lastSelectionSource: SelectionSource = .programmatic

    // 滚动状态 (v0.9.3 - 快速滚动时禁用悬停高亮)
    var isScrolling: Bool = false
    private var scrollEndTask: Task<Void, Never>?

    // 搜索版本号 - 用于防止旧搜索覆盖新结果 (v0.10.4)
    private var searchVersion: Int = 0

    // 分页状态
    var canLoadMore: Bool = false
    var loadedCount: Int = 0
    var totalCount: Int = 0

    // 性能统计
    var performanceSummary: PerformanceSummary?

    // 存储统计
    var storageStats: (itemCount: Int, sizeBytes: Int) = (0, 0)
    // v0.15.2: 磁盘占用统计（带 120 秒缓存）
    private var diskSizeCache: (size: Int, timestamp: Date)? = nil
    private let diskSizeCacheTTL: TimeInterval = 120  // 120 秒缓存
    var diskSizeBytes: Int = 0

    /// v0.15.2: 显示格式 "内容大小 / 磁盘占用"
    var storageSizeText: String {
        let contentSize = formatBytes(storageStats.sizeBytes)
        let diskSize = formatBytes(diskSizeBytes)
        return "\(contentSize) / \(diskSize)"
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(max(0, bytes)) / 1024
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
    private var loadMoreTask: Task<Void, Never>?
    /// v0.22: 防抖刷新 recentApps 的任务
    private var recentAppsRefreshTask: Task<Void, Never>?

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
            // 停止失败的服务（防止资源泄漏）
            service.stop()
            // 降级到 Mock 服务并启动
            let mockService = MockClipboardService()
            service = mockService
            do {
                try await mockService.start()
                print("⚠️ Falling back to Mock Clipboard Service (started)")
            } catch {
                print("❌ Mock service also failed to start: \(error)")
            }
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
    /// v0.17.1: 添加任务等待逻辑，确保应用退出时数据完整性
    /// v0.20: 移除 RunLoop 轮询，避免阻塞主线程
    /// v0.22: 添加 recentAppsRefreshTask 取消
    func stop() {
        // 1. 取消所有任务
        eventTask?.cancel()
        searchTask?.cancel()
        loadMoreTask?.cancel()
        scrollEndTask?.cancel()
        recentAppsRefreshTask?.cancel()

        // 2. 清理引用（不再阻塞等待，让系统自然清理）
        // 注意：取消任务后，任务会在下一个 await 点检查取消状态并退出
        // 不需要阻塞主线程等待，这会导致应用退出时卡顿
        eventTask = nil
        searchTask = nil
        loadMoreTask = nil
        scrollEndTask = nil
        recentAppsRefreshTask = nil

        // 3. 通过协议方法停止服务
        // service.stop() 内部会处理必要的清理工作
        service.stop()
    }

    // MARK: - Settings Management

    var settings: SettingsDTO = .default

    func loadSettings() async {
        do {
            settings = try await service.getSettings()
            searchMode = settings.defaultSearchMode
        } catch {
            print("Failed to load settings: \(error)")
            searchMode = SettingsDTO.default.defaultSearchMode  // 降级处理
        }
    }

    /// 加载最近使用的 app 列表（用于过滤菜单）
    func loadRecentApps() async {
        do {
            recentApps = try await service.getRecentApps(limit: 10)
            // v0.12: 预加载应用图标，避免滚动时主线程阻塞
            preloadAppIcons()
        } catch {
            print("Failed to load recent apps: \(error)")
        }
    }

    /// v0.22: 防抖刷新 recentApps，避免快速复制时多次调用
    private func scheduleRecentAppsRefresh() {
        recentAppsRefreshTask?.cancel()
        recentAppsRefreshTask = Task {
            // 防抖 500ms
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await loadRecentApps()
        }
    }

    /// v0.12: 后台预加载应用图标
    private func preloadAppIcons() {
        let appsToPreload = recentApps
        Task.detached(priority: .background) {
            for bundleID in appsToPreload {
                IconCacheSync.shared.preloadIcon(bundleID: bundleID)
            }
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
    /// v0.10.4: 移除嵌套 Task，直接在 MainActor 上下文执行
    func startEventListener() {
        eventTask = Task { [weak self] in
            guard let self = self else { return }
            for await event in self.service.eventStream {
                guard !Task.isCancelled else { break }
                // 直接调用，因为 AppState 已经是 @MainActor
                await self.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: ClipboardEvent) async {
        switch event {
        case .newItem(let item):
            // 新项目或重复项目：移除旧位置
            let wasExisting = items.contains(where: { $0.id == item.id })
            items.removeAll { $0.id == item.id }

            // v0.16.1: 只有匹配当前过滤条件时才插入到列表
            if matchesCurrentFilters(item) {
                items.insert(item, at: 0)
            }

            // v0.16.2: 手动失效缓存（removeAll/insert 不触发 didSet）
            invalidatePinnedCache()

            // 只有真正新增时才增加 totalCount
            if !wasExisting {
                totalCount += 1
            }
            // v0.22: 如果是新 app，刷新 app 列表（使用防抖避免频繁调用）
            if let bundleID = item.appBundleID, !recentApps.contains(bundleID) {
                scheduleRecentAppsRefresh()
            }
        case .itemUpdated(let item):
            // 更新的项目：移除旧位置，插入到顶部（用于复制置顶）
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
            // v0.16.2: 手动失效缓存
            invalidatePinnedCache()
        case .itemDeleted(let id):
            items.removeAll { $0.id == id }
            // v0.16.2: 手动失效缓存
            invalidatePinnedCache()
            totalCount -= 1
        case .itemPinned(let id):
            // v0.16.2: 直接更新 items 数组中对应项目的 isPinned 属性
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withPinned(true)
                invalidatePinnedCache()
            }
        case .itemUnpinned(let id):
            // v0.16.2: 直接更新 items 数组中对应项目的 isPinned 属性
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withPinned(false)
                invalidatePinnedCache()
            }
        case .settingsChanged:
            // 1. 先 reload 最新设置
            await loadSettings()
            // 2. 兜底应用热键（无回调时记录日志，便于调试 headless/测试场景）
            if let handler = applyHotKeyHandler {
                handler(settings.hotkeyKeyCode, settings.hotkeyModifiers)
            } else {
                print("⚠️ settingsChanged: applyHotKeyHandler not registered, hotkey may be out of sync")
            }
            await load()
        }
    }

    /// v0.16.1: 检查项目是否匹配当前过滤条件
    /// 用于 handleEvent(.newItem) 决定是否将新项目插入到显示列表
    /// v0.22: 支持 typeFilters 多类型过滤
    private func matchesCurrentFilters(_ item: ClipboardItemDTO) -> Bool {
        // 检查 typeFilters（多类型过滤，优先）
        if let typeFilters = typeFilters, !typeFilters.contains(item.type) {
            return false
        }
        // 检查 typeFilter（单类型过滤）
        if typeFilters == nil, let typeFilter = typeFilter, item.type != typeFilter {
            return false
        }
        // 检查 appFilter
        if let appFilter = appFilter, item.appBundleID != appFilter {
            return false
        }
        // 搜索词过滤：有搜索词时，新项目不自动插入
        // 用户需要清除搜索或刷新才能看到
        if !searchQuery.isEmpty {
            return false
        }
        return true
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

            // v0.15.2: 更新磁盘占用统计（带缓存）
            await refreshDiskSizeIfNeeded()

            // 记录首屏加载性能
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            await PerformanceMetrics.shared.recordLoadLatency(elapsedMs)
            performanceSummary = await PerformanceMetrics.shared.getSummary()
        } catch {
            print("Failed to load items: \(error)")
        }
    }

    /// v0.15.2: 刷新磁盘占用统计（带 120 秒缓存）
    private func refreshDiskSizeIfNeeded() async {
        // 检查缓存是否有效
        if let cache = diskSizeCache,
           Date().timeIntervalSince(cache.timestamp) < diskSizeCacheTTL {
            diskSizeBytes = cache.size
            return
        }

        // 获取详细统计
        do {
            let detailedStats = try await service.getDetailedStorageStats()
            diskSizeBytes = detailedStats.totalSizeBytes
            diskSizeCache = (diskSizeBytes, Date())
        } catch {
            print("Failed to get disk size: \(error)")
        }
    }

    /// 加载更多（懒加载）- 符合 v0.md 的分页设计
    /// 滚动事件处理 - 快速滚动时禁用悬停高亮
    /// v0.10.4: 使用 Task 替代 Timer，自动取消防止泄漏
    func onScroll() {
        isScrolling = true
        scrollEndTask?.cancel()
        scrollEndTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            guard !Task.isCancelled else { return }
            isScrolling = false
        }
    }

    /// v0.10.4: 改进任务取消检查，确保状态变更前验证
    func loadMore() async {
        // 取消之前的 loadMore 任务，防止快速滚动时重复加载
        loadMoreTask?.cancel()

        loadMoreTask = Task {
            // 先检查取消状态
            guard !Task.isCancelled else { return }
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
                        typeFilters: typeFilters,
                        limit: 50,
                        offset: loadedCount
                    )
                    let result = try await service.search(query: request)
                    // 在状态变更前再次检查取消状态
                    guard !Task.isCancelled else { return }
                    items.append(contentsOf: result.items)
                    // v0.16.2: 手动失效缓存
                    invalidatePinnedCache()
                    loadedCount = items.count
                    totalCount = result.total
                    canLoadMore = result.hasMore
                } else {
                    let moreItems = try await service.fetchRecent(limit: 100, offset: loadedCount)
                    // 在状态变更前再次检查取消状态
                    guard !Task.isCancelled else { return }
                    items.append(contentsOf: moreItems)
                    // v0.16.2: 手动失效缓存
                    invalidatePinnedCache()
                    loadedCount = items.count
                    canLoadMore = loadedCount < totalCount
                }
            } catch {
                if !Task.isCancelled {
                    print("Failed to load more: \(error)")
                }
            }
        }

        // v0.20: 等待任务完成，但使用 _ = 忽略返回值
        // 这是安全的，因为 Task 内部的所有 await 操作都会正确让出控制权
        _ = await loadMoreTask?.value
    }

    /// 搜索（带防抖）- 符合 v0.md 的 150-200ms 防抖设计
    /// v0.10.4: 添加搜索版本号，防止旧搜索覆盖新结果
    func search() {
        searchTask?.cancel()

        // 如果没有搜索词且没有过滤条件，直接加载全部
        if searchQuery.isEmpty && appFilter == nil && typeFilter == nil && typeFilters == nil {
            Task { await load() }
            return
        }

        // 递增搜索版本号
        searchVersion += 1
        let currentVersion = searchVersion

        searchTask = Task {
            // 防抖 150ms
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            // 检查版本号，确保不是过期的搜索
            guard currentVersion == searchVersion else { return }

            isLoading = true
            defer { isLoading = false }

            do {
                let startTime = CFAbsoluteTimeGetCurrent()

                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    appFilter: appFilter,
                    typeFilter: typeFilter,
                    typeFilters: typeFilters,
                    limit: 50,
                    offset: 0
                )
                let result = try await service.search(query: request)

                // 再次检查版本号和取消状态，确保状态更新的原子性
                guard !Task.isCancelled, currentVersion == searchVersion else { return }

                // 原子更新所有状态
                items = result.items
                totalCount = result.total
                loadedCount = result.items.count
                canLoadMore = result.hasMore

                // 记录搜索性能
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                await PerformanceMetrics.shared.recordSearchLatency(elapsedMs)
                performanceSummary = await PerformanceMetrics.shared.getSummary()
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
    /// v0.16.2: 移除 await load()，由 handleEvent(.itemPinned/.itemUnpinned) 统一处理
    func togglePin(_ item: ClipboardItemDTO) async {
        do {
            if item.isPinned {
                try await service.unpin(itemID: item.id)
            } else {
                try await service.pin(itemID: item.id)
            }
            // 状态更新由 handleEvent 统一处理，避免重复刷新
        } catch {
            print("Pin toggle failed: \(error)")
        }
    }

    /// 删除项目
    /// v0.16.1: 移除 totalCount 递减，由 handleEvent(.itemDeleted) 统一处理
    func delete(_ item: ClipboardItemDTO) async {
        do {
            try await service.delete(itemID: item.id)
            items.removeAll { $0.id == item.id }
            // v0.16.2: 手动失效缓存
            invalidatePinnedCache()
            // totalCount 由 handleEvent(.itemDeleted) 统一递减，避免重复
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
