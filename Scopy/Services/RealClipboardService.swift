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

    /// v0.10.7: 事件流关闭标志，防止向已关闭的流发送数据
    private var isEventStreamFinished = false

    private(set) var eventStream: AsyncStream<ClipboardEvent>

    /// v0.10.7: 安全发送事件，检查流是否已关闭
    private func yieldEvent(_ event: ClipboardEvent) {
        guard !isEventStreamFinished else { return }
        eventContinuation?.yield(event)
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
    func stop() {
        guard !isEventStreamFinished else { return }
        isEventStreamFinished = true

        // 1. 先取消 monitorTask
        monitorTask?.cancel()

        // 2. 停止监控（这会取消 ClipboardMonitor 的任务队列）
        monitor.stopMonitoring()

        // 3. 清理 monitorTask 引用
        monitorTask = nil

        // 4. 显式关闭事件流 continuation
        eventContinuation?.finish()

        // 5. 关闭存储
        storage.close()
    }

    // MARK: - ClipboardServiceProtocol Implementation

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let items = try storage.fetchRecent(limit: limit, offset: offset)
        return items.map { toDTO($0) }
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        // Invalidate cache on new search
        if query.offset == 0 {
            search.invalidateCache()
        }

        let result = try await search.search(request: query)
        return SearchResultPage(
            items: result.items.map { toDTO($0) },
            total: result.total,
            hasMore: result.hasMore
        )
    }

    func pin(itemID: UUID) async throws {
        try storage.setPin(itemID, pinned: true)
        search.invalidateCache()
        yieldEvent(.itemPinned(itemID))
    }

    func unpin(itemID: UUID) async throws {
        try storage.setPin(itemID, pinned: false)
        search.invalidateCache()
        yieldEvent(.itemUnpinned(itemID))
    }

    func delete(itemID: UUID) async throws {
        try storage.deleteItem(itemID)
        search.invalidateCache()
        yieldEvent(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        try storage.deleteAllExceptPinned()
        search.invalidateCache()
        yieldEvent(.settingsChanged)
    }

    func copyToClipboard(itemID: UUID) async throws {
        guard let item = try storage.findByID(itemID) else { return }

        switch item.type {
        case .text:
            monitor.copyToClipboard(text: item.plainText)
        case .rtf, .html, .image:
            // 优先使用内联数据（小内容），否则读取外部存储
            var data: Data? = item.rawData
            if data == nil, let storageRef = item.storageRef {
                data = try storage.loadExternalData(path: storageRef)
            }

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
            // 尝试从 inline rawData 或 external storage 恢复文件 URL
            var urlData: Data? = item.rawData
            if urlData == nil, let storageRef = item.storageRef {
                urlData = try? storage.loadExternalData(path: storageRef)
            }

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
        try? storage.updateItem(updated)

        // 生成事件让 UI 刷新（置顶该条目）
        search.invalidateCache()
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
        try? storage.performCleanup()

        yieldEvent(.settingsChanged)
    }

    func getSettings() async throws -> SettingsDTO {
        return loadSettingsFromDefaults()
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let count = try storage.getItemCount()
        let size = try storage.getTotalSize()
        return (count, size)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let count = try storage.getItemCount()
        // 使用实际文件大小而非 SUM(size_bytes)
        let dbSize = storage.getDatabaseFileSize()
        let externalSize = try storage.getExternalStorageSize()
        let dbPath = storage.databaseFilePath

        return StorageStatsDTO(
            itemCount: count,
            databaseSizeBytes: dbSize,
            externalStorageSizeBytes: externalSize,
            totalSizeBytes: dbSize + externalSize,
            databasePath: dbPath
        )
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        guard let item = try storage.findByID(itemID) else { return nil }
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
            let storedItem = try storage.upsertItem(content)

            // 图片类型：生成缩略图
            if content.type == .image, settings.showImageThumbnails {
                if let imageData = storage.getOriginalImageData(for: storedItem) {
                    _ = storage.generateThumbnail(
                        from: imageData,
                        contentHash: storedItem.contentHash,
                        maxHeight: settings.thumbnailHeight
                    )
                }
            }

            search.invalidateCache()
            yieldEvent(.newItem(toDTO(storedItem)))

            // Periodic cleanup
            try? storage.performCleanup()
        } catch {
            print("Failed to store clipboard item: \(error)")
        }
    }

    private func toDTO(_ item: StorageService.StoredItem) -> ClipboardItemDTO {
        // 图片类型：检查是否有缩略图，没有则懒加载生成
        var thumbnailPath: String? = nil
        if item.type == .image && settings.showImageThumbnails {
            // 先检查是否已有缩略图
            thumbnailPath = storage.getThumbnailPath(for: item.contentHash)

            // 如果没有，即时生成（懒加载）
            if thumbnailPath == nil {
                if let imageData = storage.getOriginalImageData(for: item) {
                    thumbnailPath = storage.generateThumbnail(
                        from: imageData,
                        contentHash: item.contentHash,
                        maxHeight: settings.thumbnailHeight
                    )
                }
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
        let searchModeString = dict["defaultSearchMode"] as? String ?? SearchMode.fuzzy.rawValue
        let searchMode = SearchMode(rawValue: searchModeString) ?? .fuzzy

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
