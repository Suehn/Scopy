import AppKit
import Foundation
import Observation

/// 应用状态 - 符合 v0.md 的 Observable 架构
@Observable
@MainActor
final class AppState {
    static let shared = AppState()

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

    // 弹窗引用（用于 AppDelegate）
    weak var appDelegate: AppDelegate?

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

    private init() {
        // 根据配置选择服务
        if Self.useMockService {
            self.service = MockClipboardService()
            print("📋 Using Mock Clipboard Service")
        } else {
            self.service = RealClipboardService()
            print("📋 Using Real Clipboard Service")
        }
    }

    /// 启动应用服务
    func start() async {
        // 如果是真实服务，需要启动
        if let realService = service as? RealClipboardService {
            do {
                try await realService.start()
                print("✅ Real Clipboard Service started")
            } catch {
                print("❌ Failed to start Real Clipboard Service: \(error)")
                // 降级到 Mock 服务
                service = MockClipboardService()
                print("⚠️ Falling back to Mock Clipboard Service")
            }
        }

        // 监听事件流
        startEventListener()

        // 加载设置
        await loadSettings()

        // 初始加载
        await load()
    }

    /// 停止应用服务
    func stop() {
        eventTask?.cancel()
        eventTask = nil

        if let realService = service as? RealClipboardService {
            realService.stop()
        }
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

    func updateSettings(_ newSettings: SettingsDTO) async {
        do {
            try await service.updateSettings(newSettings)
            settings = newSettings
        } catch {
            print("Failed to update settings: \(error)")
        }
    }

    /// 监听剪贴板事件
    private func startEventListener() {
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
            // 新项目添加到顶部
            if !items.contains(where: { $0.id == item.id }) {
                items.insert(item, at: 0)
                totalCount += 1
            }
        case .itemDeleted(let id):
            items.removeAll { $0.id == id }
            totalCount -= 1
        case .itemPinned, .itemUnpinned:
            // 刷新以获取最新状态
            await load()
        case .settingsChanged:
            // 设置变化时刷新
            await load()
        }
    }

    /// 初始加载
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            items = try await service.fetchRecent(limit: 50, offset: 0)
            loadedCount = items.count
            let stats = try await service.getStorageStats()
            totalCount = stats.itemCount
            storageStats = stats
            canLoadMore = loadedCount < totalCount
        } catch {
            print("Failed to load items: \(error)")
        }
    }

    /// 加载更多（懒加载）- 符合 v0.md 的分页设计
    func loadMore() async {
        guard canLoadMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let moreItems = try await service.fetchRecent(limit: 100, offset: loadedCount)
            items.append(contentsOf: moreItems)
            loadedCount = items.count
            canLoadMore = loadedCount < totalCount
        } catch {
            print("Failed to load more: \(error)")
        }
    }

    /// 搜索（带防抖）- 符合 v0.md 的 150-200ms 防抖设计
    func search() {
        searchTask?.cancel()

        if searchQuery.isEmpty {
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
                let request = SearchRequest(
                    query: searchQuery,
                    mode: searchMode,
                    limit: 50,
                    offset: 0
                )
                let result = try await service.search(query: request)
                items = result.items
                totalCount = result.total
                loadedCount = result.items.count
                canLoadMore = result.hasMore
            } catch {
                print("Search failed: \(error)")
            }
        }
    }

    /// 选择并复制
    func select(_ item: ClipboardItemDTO) async {
        do {
            try await service.copyToClipboard(itemID: item.id)
            appDelegate?.panel?.close()
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
        if let currentID = selectedID,
           let currentIndex = items.firstIndex(where: { $0.id == currentID }),
           currentIndex > 0 {
            selectedID = items[currentIndex - 1].id
        } else {
            selectedID = items.last?.id
        }
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
    static func forTesting(service: ClipboardServiceProtocol) -> AppState {
        let state = AppState()
        state.service = service
        return state
    }
}
