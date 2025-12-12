import AppKit
import Foundation
import SQLite3

/// RealClipboardService - 真实剪贴板服务实现
/// 整合 ClipboardMonitor + StorageService + SearchService
/// 符合 v0.md 的完整后端架构
@MainActor
final class RealClipboardService: ClipboardServiceProtocol {
    // MARK: - Properties

    private let monitor: ClipboardMonitor
    private let storage: StorageService
    private let search: SearchService
    private var settings: SettingsDTO = .default

    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?
    private var monitorTask: Task<Void, Never>?

    // MARK: - Cleanup Scheduling (v0.26)

    /// 复制热路径清理节流：避免每次新条目都执行 O(N) orphan 扫描
    private var cleanupTask: Task<Void, Never>?
    private var isCleanupRunning = false
    private var lastLightCleanupAt: Date = .distantPast
    private var lastFullCleanupAt: Date = .distantPast
    private let lightCleanupInterval: TimeInterval = 60        // 至少 60s 一次
    private let fullCleanupInterval: TimeInterval = 3600       // orphan + vacuum 低频 1h 一次
    private let cleanupDebounceDelay: TimeInterval = 2.0       // 连续复制合并到一次清理

    /// v0.10.7: 事件流关闭标志，防止向已关闭的流发送数据
    private var isEventStreamFinished = false

    /// v0.20: 保护事件流状态的锁，防止 stop() 和 yieldEvent() 之间的竞态
    private let eventStreamLock = NSLock()

    private(set) var eventStream: AsyncStream<ClipboardEvent>

    /// v0.10.7: 安全发送事件，检查流是否已关闭
    /// v0.20: 添加锁保护，防止与 stop() 竞态
    private func yieldEvent(_ event: ClipboardEvent) {
        eventStreamLock.withLock {
            guard !isEventStreamFinished else { return }
            eventContinuation?.yield(event)
        }
    }

    // For direct database access (needed by SearchService)
    private var db: OpaquePointer? {
        // Access storage's db through a method we'll add
        nil // SearchService will use storage directly
    }

    // MARK: - Initialization

    init(databasePath: String? = nil) {
        self.monitor = ClipboardMonitor()
        self.storage = StorageService(databasePath: databasePath)
        self.search = SearchService(storage: storage)

        var continuation: AsyncStream<ClipboardEvent>.Continuation!
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Open storage
        try storage.open()

        // Set up search service with database reference
        search.setDatabase(storage.database)

        // Load settings
        settings = try await getSettings()

        // Apply settings to cleanup
        storage.cleanupSettings.maxItems = settings.maxItems
        storage.cleanupSettings.maxSmallStorageMB = settings.maxStorageMB

        // v0.15: Run orphan cleanup on startup to clean up any orphaned files（异步触发，避免阻塞启动路径）
        Task { [weak self] in
            guard let storage = self?.storage else { return }
            try? storage.cleanupOrphanedFiles()
        }

        // Start clipboard monitoring
        monitor.startMonitoring()

        // Listen for clipboard events
        monitorTask = Task { [weak self] in
            guard let self = self else { return }
            for await content in self.monitor.contentStream {
                // 避免阻塞事件循环
                Task { @MainActor in
                    await self.handleNewContent(content)
                }
            }
        }
    }

    /// v0.10.4: 显式关闭事件流，防止泄漏
    /// v0.10.7: 添加 isEventStreamFinished 标志，防止重复关闭和向已关闭流发送数据
    /// v0.10.8: 改进 monitorTask 生命周期管理，确保任务正确取消
    /// v0.17.1: 添加任务等待逻辑，确保应用退出时数据完整性
    /// v0.19: 修复等待逻辑 - isCancelled 只表示请求取消，不表示任务完成
    /// v0.20: 移除 RunLoop 轮询，避免阻塞主线程
    /// v0.20: 使用锁保护事件流状态，确保与 yieldEvent() 互斥
    /// v0.22: 修复竞态 - 在锁内获取 continuation 引用，锁外调用 finish()
    func stop() {
        // 使用锁保护状态检查和设置，同时获取 continuation 引用
        // 这确保 yieldEvent() 不会在我们设置 isEventStreamFinished 后仍然 yield
        let continuation = eventStreamLock.withLock { () -> AsyncStream<ClipboardEvent>.Continuation? in
            guard !isEventStreamFinished else { return nil }
            isEventStreamFinished = true
            let cont = eventContinuation
            eventContinuation = nil  // 清空引用，防止后续 yieldEvent 使用
            return cont
        }
        guard let continuation = continuation else { return }

        // 1. 停止监控（这会取消 ClipboardMonitor 的任务队列）
        // 必须先停止监控，这样 contentStream 会结束，monitorTask 的 for-await 循环才会退出
        monitor.stopMonitoring()

        // 2. 取消 monitorTask
        monitorTask?.cancel()

        // 3. 清理 monitorTask 引用（不再阻塞等待）
        // 由于 contentStream 已结束，任务会在下一个 await 点自然退出
        // 不需要阻塞主线程等待，这会导致应用退出时卡顿
        monitorTask = nil

        // 3.5 取消清理任务
        cleanupTask?.cancel()
        cleanupTask = nil

        // 4. 显式关闭事件流 continuation（在锁外执行，避免死锁）
        continuation.finish()

        // 5. 关闭存储（执行 WAL checkpoint）
        storage.close()
    }

    // MARK: - ClipboardServiceProtocol Implementation

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let items = try storage.fetchRecent(limit: limit, offset: offset)
        return items.map { toDTO($0) }
    }

    /// v0.19: 移除搜索时的缓存清除，缓存只在数据变更时失效
    /// 原逻辑在每次新搜索时清除缓存，导致用户快速输入时频繁刷新
    func search(query: SearchRequest) async throws -> SearchResultPage {
        let result = try await search.search(request: query)
        return SearchResultPage(
            items: result.items.map { toDTO($0) },
            total: result.total,
            hasMore: result.hasMore
        )
    }

    func pin(itemID: UUID) async throws {
        try storage.setPin(itemID, pinned: true)
        search.handlePinnedChange(id: itemID, pinned: true)
        yieldEvent(.itemPinned(itemID))
    }

    func unpin(itemID: UUID) async throws {
        try storage.setPin(itemID, pinned: false)
        search.handlePinnedChange(id: itemID, pinned: false)
        yieldEvent(.itemUnpinned(itemID))
    }

    func delete(itemID: UUID) async throws {
        try storage.deleteItem(itemID)
        search.handleDeletion(id: itemID)
        yieldEvent(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        try storage.deleteAllExceptPinned()
        search.handleClearAll()
        yieldEvent(.settingsChanged)
    }

    /// v0.22: 修复图片数据丢失问题 - 使用 getOriginalImageData 统一获取数据
    func copyToClipboard(itemID: UUID) async throws {
        guard let item = try storage.findByID(itemID) else { return }

        switch item.type {
        case .text:
            monitor.copyToClipboard(text: item.plainText)
        case .rtf, .html, .image:
            // v0.22: 使用 getOriginalImageData 统一获取数据，确保从数据库重新加载
            // 这修复了 SearchService 缓存中 rawData 为 nil 导致的数据丢失问题
            let data = storage.getOriginalImageData(for: item)

            if let data = data {
                let pasteboardType: NSPasteboard.PasteboardType
                switch item.type {
                case .rtf: pasteboardType = .rtf
                case .html: pasteboardType = .html
                case .image: pasteboardType = .png
                default: pasteboardType = .string
                }
                monitor.copyToClipboard(data: data, type: pasteboardType)
            }
        case .file:
            // v0.22: 使用 getOriginalImageData 统一获取数据（虽然是文件类型，但数据获取逻辑相同）
            let urlData = storage.getOriginalImageData(for: item)

            if let data = urlData,
               let fileURLs = ClipboardMonitor.deserializeFileURLs(data),
               !fileURLs.isEmpty {
                // 使用真实的文件 URL，支持 Finder 粘贴
                monitor.copyToClipboard(fileURLs: fileURLs)
            } else {
                // 回退：从路径字符串重建 URL
                let paths = item.plainText.components(separatedBy: "\n")
                let fileURLs = paths.compactMap { URL(fileURLWithPath: $0) }
                if !fileURLs.isEmpty {
                    monitor.copyToClipboard(fileURLs: fileURLs)
                } else {
                    // 最后回退：复制路径文本
                    monitor.copyToClipboard(text: item.plainText)
                }
            }
        case .other:
            monitor.copyToClipboard(text: item.plainText)
        }

        // Update usage stats
        var updated = item
        updated.lastUsedAt = Date()
        updated.useCount += 1
        do {
            try storage.updateItem(updated)
        } catch {
            print("Failed to update item usage stats: \(error)")
        }

        // 生成事件让 UI 刷新（置顶该条目）
        search.handleUpsertedItem(updated)
        yieldEvent(.itemUpdated(toDTO(updated)))
    }

    /// v0.10.7: 先写 UserDefaults，后更新内存，防止崩溃时设置丢失
    func updateSettings(_ newSettings: SettingsDTO) async throws {
        let oldHeight = settings.thumbnailHeight
        let oldShowThumbnails = settings.showImageThumbnails

        // v0.10.7: 先持久化到磁盘，确保崩溃时不丢失
        saveSettingsToDefaults(newSettings)

        // 后更新内存
        settings = newSettings

        // Update cleanup settings
        storage.cleanupSettings.maxItems = newSettings.maxItems
        storage.cleanupSettings.maxSmallStorageMB = newSettings.maxStorageMB

        // 如果缩略图高度改变或开关状态改变，清理旧缩略图缓存（懒加载：显示时重新生成）
        if oldHeight != newSettings.thumbnailHeight || oldShowThumbnails != newSettings.showImageThumbnails {
            storage.clearThumbnailCache()
        }

        // Trigger cleanup if needed
        // v0.19: 添加错误日志，便于问题追踪
        do {
            try storage.performCleanup()
        } catch {
            print("⚠️ RealClipboardService: Cleanup failed after settings update: \(error.localizedDescription)")
        }

        yieldEvent(.settingsChanged)
    }

    func getSettings() async throws -> SettingsDTO {
        return loadSettingsFromDefaults()
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let count = try storage.getItemCount()
        // v0.15.2: 返回实际磁盘占用大小，而非数据库中记录的 size_bytes
        let dbSize = storage.getDatabaseFileSize()
        let externalSize = try await storage.getExternalStorageSizeForStats()
        let thumbnailSize = await storage.getThumbnailCacheSize()
        return (count, dbSize + externalSize + thumbnailSize)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let count = try storage.getItemCount()
        // 使用实际文件大小而非 SUM(size_bytes)
        let dbSize = storage.getDatabaseFileSize()
        // v0.15.2: 使用强制刷新版本，避免缓存导致显示不准确
        let externalSize = try await storage.getExternalStorageSizeForStats()
        let thumbnailSize = await storage.getThumbnailCacheSize()
        let dbPath = storage.databaseFilePath

        return StorageStatsDTO(
            itemCount: count,
            databaseSizeBytes: dbSize,
            externalStorageSizeBytes: externalSize,
            thumbnailSizeBytes: thumbnailSize,
            totalSizeBytes: dbSize + externalSize + thumbnailSize,
            databasePath: dbPath
        )
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        guard let item = try storage.findByID(itemID) else { return nil }

        // 大图片优先走外部文件后台读取，避免主线程磁盘 I/O
        if let storagePath = item.storageRef {
            return await Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: storagePath))
            }.value
        }

        // 小图片直接返回内联数据
        if let rawData = item.rawData {
            return rawData
        }

        // 兜底：从数据库重新加载（理论上 findByID 已带 rawData）
        return storage.getOriginalImageData(for: item)
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        return try storage.getRecentApps(limit: limit)
    }

    // MARK: - Private Methods

    private func handleNewContent(_ content: ClipboardMonitor.ClipboardContent) async {
        // Skip if not saving images/files based on settings
        if content.type == .image && !settings.saveImages { return }
        if content.type == .file && !settings.saveFiles { return }

        do {
            let storedItem = try await storage.upsertItem(content)

            // 图片类型：异步生成缩略图（后台，避免阻塞复制热路径）
            if content.type == .image, settings.showImageThumbnails {
                if storage.getThumbnailPath(for: storedItem.contentHash) == nil {
                    scheduleThumbnailGeneration(for: storedItem)
                }
            }

            search.handleUpsertedItem(storedItem)
            yieldEvent(.newItem(toDTO(storedItem)))

            scheduleCleanup()
        } catch {
            print("⚠️ RealClipboardService: Failed to store clipboard item: \(error.localizedDescription)")
        }
    }

    /// v0.26: 防抖 + 节流清理
    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(cleanupDebounceDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.runCleanupIfNeeded()
        }
    }

    private func runCleanupIfNeeded() async {
        guard !isCleanupRunning else { return }
        isCleanupRunning = true
        defer { isCleanupRunning = false }

        let now = Date()
        let needsFull = now.timeIntervalSince(lastFullCleanupAt) >= fullCleanupInterval
        let needsLight = now.timeIntervalSince(lastLightCleanupAt) >= lightCleanupInterval

        guard needsLight || needsFull else { return }

        let mode: StorageService.CleanupMode = needsFull ? .full : .light
        do {
            try storage.performCleanup(mode: mode)
            lastLightCleanupAt = now
            if needsFull {
                lastFullCleanupAt = now
            }
        } catch {
            print("⚠️ RealClipboardService: Scheduled cleanup failed: \(error.localizedDescription)")
        }
    }

    private func toDTO(_ item: StorageService.StoredItem) -> ClipboardItemDTO {
        // 图片类型：检查是否有缩略图
        var thumbnailPath: String? = nil
        if item.type == .image && settings.showImageThumbnails {
            // 先检查是否已有缩略图
            thumbnailPath = storage.getThumbnailPath(for: item.contentHash)

            // v0.22.1: 如果没有缩略图，在后台异步生成，不阻塞主线程
            // 缩略图生成完成后，UI 会在下次刷新时显示
            if thumbnailPath == nil {
                scheduleThumbnailGeneration(for: item)
            }
        }

        return ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes,
            thumbnailPath: thumbnailPath,
            storageRef: item.storageRef
        )
    }

    /// v0.22.1: 后台异步生成缩略图，避免阻塞主线程
    /// v0.23: 使用 actor 替代 nonisolated(unsafe)，确保线程安全
    private func scheduleThumbnailGeneration(for item: StorageService.StoredItem) {
        let contentHash = item.contentHash
        let maxHeight = settings.thumbnailHeight
        let storageRef = storage  // 捕获 storage 引用

        // 在后台线程生成缩略图
        Task.detached(priority: .utility) {
            // 使用 actor 安全地检查和标记生成状态
            let shouldGenerate = await ThumbnailGenerationTracker.shared.tryMarkInProgress(contentHash)
            guard shouldGenerate else { return }

            defer {
                Task {
                    await ThumbnailGenerationTracker.shared.markCompleted(contentHash)
                }
            }

            // 获取原图数据（大图走外部文件后台读取；小图必要时回主线程 DB reload）
            let imageData: Data?
            if let storagePath = item.storageRef {
                imageData = try? Data(contentsOf: URL(fileURLWithPath: storagePath))
            } else if let rawData = item.rawData {
                imageData = rawData
            } else {
                imageData = await MainActor.run { storageRef.getOriginalImageData(for: item) }
            }

            guard let imageData = imageData else { return }

            guard let pngData = StorageService.makeThumbnailPNG(from: imageData, maxHeight: maxHeight) else { return }

            // 小文件写入留在主线程（原子写入），避免跨线程触碰 storage 的 actor 状态
            await MainActor.run {
                try? storageRef.saveThumbnail(pngData, for: contentHash)
            }
        }
    }

    // MARK: - Settings Persistence

    private let settingsKey = "ScopySettings"

    private func saveSettingsToDefaults(_ settings: SettingsDTO) {
        let dict: [String: Any] = [
            "maxItems": settings.maxItems,
            "maxStorageMB": settings.maxStorageMB,
            "saveImages": settings.saveImages,
            "saveFiles": settings.saveFiles,
            "defaultSearchMode": settings.defaultSearchMode.rawValue,
            "hotkeyKeyCode": settings.hotkeyKeyCode,
            "hotkeyModifiers": settings.hotkeyModifiers,
            "showImageThumbnails": settings.showImageThumbnails,
            "thumbnailHeight": settings.thumbnailHeight,
            "imagePreviewDelay": settings.imagePreviewDelay
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettingsFromDefaults() -> SettingsDTO {
        guard let dict = UserDefaults.standard.dictionary(forKey: settingsKey) else {
            return .default
        }
        let searchModeString = dict["defaultSearchMode"] as? String ?? SettingsDTO.default.defaultSearchMode.rawValue
        let searchMode = SearchMode(rawValue: searchModeString) ?? SettingsDTO.default.defaultSearchMode

        return SettingsDTO(
            maxItems: dict["maxItems"] as? Int ?? SettingsDTO.default.maxItems,
            maxStorageMB: dict["maxStorageMB"] as? Int ?? SettingsDTO.default.maxStorageMB,
            saveImages: dict["saveImages"] as? Bool ?? SettingsDTO.default.saveImages,
            saveFiles: dict["saveFiles"] as? Bool ?? SettingsDTO.default.saveFiles,
            defaultSearchMode: searchMode,
            hotkeyKeyCode: (dict["hotkeyKeyCode"] as? NSNumber)?.uint32Value ?? SettingsDTO.default.hotkeyKeyCode,
            hotkeyModifiers: (dict["hotkeyModifiers"] as? NSNumber)?.uint32Value ?? SettingsDTO.default.hotkeyModifiers,
            showImageThumbnails: dict["showImageThumbnails"] as? Bool ?? SettingsDTO.default.showImageThumbnails,
            thumbnailHeight: dict["thumbnailHeight"] as? Int ?? SettingsDTO.default.thumbnailHeight,
            imagePreviewDelay: dict["imagePreviewDelay"] as? Double ?? SettingsDTO.default.imagePreviewDelay
        )
    }
}

// MARK: - Service Factory

/// Factory for creating clipboard services
enum ClipboardServiceFactory {
    /// Create appropriate service based on environment
    @MainActor
    static func create(useMock: Bool = false, databasePath: String? = nil) -> ClipboardServiceProtocol {
        if useMock {
            return MockClipboardService()
        } else {
            return RealClipboardService(databasePath: databasePath)
        }
    }

    /// Create service for testing with in-memory database
    @MainActor
    static func createForTesting() -> RealClipboardService {
        RealClipboardService(databasePath: ":memory:")
    }
}
