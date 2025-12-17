import AppKit
import Foundation

/// Application 层门面（vNext）：统一组合 monitor/storage/search/settings，并由 actor 持有事件 continuation。
///
/// 说明（Phase 4 约束）：
/// - `ClipboardMonitor` / `StorageService` 为 `@MainActor`，因此该 actor 在内部通过 `MainActor.run {}` 或跨 MainActor 调用处理边界。
/// - UI 仍通过 `@MainActor ClipboardServiceProtocol` 调用 `RealClipboardService`（adapter），由 adapter 转发到该 actor。
actor ClipboardService {
    // MARK: - Types

    enum ClipboardServiceError: Error, LocalizedError {
        case notStarted

        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "ClipboardService is not started"
            }
        }
    }

    // MARK: - Properties

    nonisolated let eventStream: AsyncStream<ClipboardEvent>

    private let databasePath: String?
    private let settingsStore: SettingsStore
    private let monitorPasteboardName: String?
    private let monitorPollingInterval: TimeInterval?

    private var monitor: ClipboardMonitor?
    private var storage: StorageService?
    private var search: SearchEngineImpl?

    private var settings: SettingsDTO = .default

    private let eventQueue: AsyncBoundedQueue<ClipboardEvent>
    private var monitorTask: Task<Void, Never>?
    private var isStarted = false

    // MARK: - Cleanup Scheduling (v0.26)

    private var cleanupTask: Task<Void, Never>?
    private var isCleanupRunning = false
    private var lastLightCleanupAt: Date = .distantPast
    private var lastFullCleanupAt: Date = .distantPast
    private let lightCleanupInterval: TimeInterval = 60
    private let fullCleanupInterval: TimeInterval = 3600
    private let cleanupDebounceDelay: TimeInterval = 2.0

    // MARK: - Initialization

    init(
        databasePath: String? = nil,
        settingsStore: SettingsStore = .shared,
        monitorPasteboardName: String? = nil,
        monitorPollingInterval: TimeInterval? = nil
    ) {
        self.databasePath = databasePath
        self.settingsStore = settingsStore
        self.monitorPasteboardName = monitorPasteboardName
        self.monitorPollingInterval = monitorPollingInterval

        let queue = AsyncBoundedQueue<ClipboardEvent>(capacity: ScopyThresholds.clipboardEventStreamMaxBufferedItems)
        self.eventQueue = queue
        self.eventStream = AsyncStream(unfolding: { await queue.dequeue() })
    }

    deinit {
        monitorTask?.cancel()
        cleanupTask?.cancel()
        Task { [eventQueue] in
            await eventQueue.finish()
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isStarted else { return }

        let loadedSettings = await settingsStore.load()

        let pasteboardName = monitorPasteboardName
        let pollingInterval = monitorPollingInterval ?? (TimeInterval(loadedSettings.clipboardPollingIntervalMs) / 1000.0)

        let monitor = await MainActor.run {
            let pasteboard: NSPasteboard
            if let pasteboardName, !pasteboardName.isEmpty {
                pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            } else {
                pasteboard = .general
            }
            return ClipboardMonitor(pasteboard: pasteboard, pollingInterval: pollingInterval)
        }

        let storage = await MainActor.run { StorageService(databasePath: databasePath) }
        let dbPath = await storage.databaseFilePath
        let search = SearchEngineImpl(dbPath: dbPath)

        do {
            try await storage.open()
            try await search.open()

            await MainActor.run {
                storage.cleanupSettings.maxItems = loadedSettings.maxItems
                storage.cleanupSettings.maxSmallStorageMB = loadedSettings.maxStorageMB
                monitor.startMonitoring()
            }

            let monitorTask = Task { [weak self] in
                guard let self else { return }
                guard let stream = await self.getMonitorStream() else { return }
                for await content in stream {
                    guard !Task.isCancelled else { break }
                    await self.handleNewContent(content)
                }
            }

            self.settings = loadedSettings
            self.monitor = monitor
            self.storage = storage
            self.search = search
            self.monitorTask = monitorTask
            self.isStarted = true

            Task { [storage] in
                try? await storage.cleanupOrphanedFiles()
            }
        } catch {
            await MainActor.run {
                monitor.stopMonitoring()
            }
            await storage.close()
            await search.close()
            throw error
        }
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false

        let monitor = monitor
        let storage = storage
        let search = search

        self.monitor = nil
        self.storage = nil
        self.search = nil

        monitorTask?.cancel()
        monitorTask = nil

        cleanupTask?.cancel()
        cleanupTask = nil

        if let monitor {
            await MainActor.run {
                monitor.stopMonitoring()
            }
        }

        if let storage {
            await storage.close()
        }

        if let search {
            await search.close()
        }
    }

    // MARK: - Data Access

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let storage = try requireStorage()
        let items = try await storage.fetchRecent(limit: limit, offset: offset)
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        let storage = try requireStorage()
        let search = try requireSearch()

        let result = try await search.search(request: query)

        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(result.items.count)
        for item in result.items {
            dtos.append(await toDTO(item, storage: storage))
        }

        return SearchResultPage(items: dtos, total: result.total, hasMore: result.hasMore)
    }

    func pin(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.setPin(itemID, pinned: true)
        await search.handlePinnedChange(id: itemID, pinned: true)
        await yieldEvent(.itemPinned(itemID))
    }

    func unpin(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.setPin(itemID, pinned: false)
        await search.handlePinnedChange(id: itemID, pinned: false)
        await yieldEvent(.itemUnpinned(itemID))
    }

    func delete(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteItem(itemID)
        await search.handleDeletion(id: itemID)
        await yieldEvent(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteAllExceptPinned()
        await search.handleClearAll()
        await yieldEvent(.itemsCleared(keepPinned: true))
    }

    func copyToClipboard(itemID: UUID) async throws {
        let monitor = try requireMonitor()
        let storage = try requireStorage()
        let search = try requireSearch()

        guard let item = try await storage.findByID(itemID) else { return }

        switch item.type {
        case .text:
            await MainActor.run {
                monitor.copyToClipboard(text: item.plainText)
            }
        case .rtf, .html, .image:
            let data = await storage.getOriginalImageData(for: item)
            if let data {
                let itemType = item.type
                let plainText: String
                if itemType == .rtf {
                    plainText = item.plainText.isEmpty
                        ? (NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? "")
                        : item.plainText
                } else if itemType == .html {
                    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                        .documentType: NSAttributedString.DocumentType.html
                    ]
                    plainText = item.plainText.isEmpty
                        ? ((try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string ?? "")
                        : item.plainText
                } else {
                    plainText = item.plainText
                }

                let pasteboardType: NSPasteboard.PasteboardType
                switch itemType {
                case .rtf: pasteboardType = .rtf
                case .html: pasteboardType = .html
                case .image: pasteboardType = .png
                default: pasteboardType = .string
                }

                await MainActor.run {
                    if itemType == .rtf || itemType == .html {
                        monitor.copyToClipboard(text: plainText, data: data, type: pasteboardType)
                    } else {
                        monitor.copyToClipboard(data: data, type: pasteboardType)
                    }
                }
            }
        case .file:
            let urlData = await storage.getOriginalImageData(for: item)
            if let data = urlData,
               let fileURLs = ClipboardMonitor.deserializeFileURLs(data),
               !fileURLs.isEmpty {
                await MainActor.run {
                    monitor.copyToClipboard(fileURLs: fileURLs)
                }
            } else {
                let paths = item.plainText.components(separatedBy: "\n")
                let fileURLs = paths.compactMap { URL(fileURLWithPath: $0) }
                if !fileURLs.isEmpty {
                    await MainActor.run {
                        monitor.copyToClipboard(fileURLs: fileURLs)
                    }
                } else {
                    await MainActor.run {
                        monitor.copyToClipboard(text: item.plainText)
                    }
                }
            }
        case .other:
            await MainActor.run {
                monitor.copyToClipboard(text: item.plainText)
            }
        }

        var updated = item
        updated.lastUsedAt = Date()
        updated.useCount += 1
        do {
            try await storage.updateItem(updated)
        } catch {
            ScopyLog.app.warning("Failed to update item usage stats: \(error.localizedDescription, privacy: .private)")
        }

        await search.handleUpsertedItem(updated)
        await yieldEvent(.itemUpdated(await toDTO(updated, storage: storage, thumbnailGenerationPriority: .userInitiated)))
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        let oldHeight = settings.thumbnailHeight
        let oldShowThumbnails = settings.showImageThumbnails
        let oldPollingMs = settings.clipboardPollingIntervalMs

        await settingsStore.save(newSettings)
        settings = newSettings

        if monitorPollingInterval == nil,
           oldPollingMs != newSettings.clipboardPollingIntervalMs,
           let monitor {
            await MainActor.run {
                monitor.setPollingInterval(TimeInterval(newSettings.clipboardPollingIntervalMs) / 1000.0)
            }
        }

        if let storage = storage {
            await MainActor.run {
                storage.cleanupSettings.maxItems = newSettings.maxItems
                storage.cleanupSettings.maxSmallStorageMB = newSettings.maxStorageMB
            }

            if oldHeight != newSettings.thumbnailHeight || oldShowThumbnails != newSettings.showImageThumbnails {
                await storage.clearThumbnailCache()
            }

            do {
                try await storage.performCleanup()
                if let search {
                    await search.invalidateCache()
                }
            } catch {
                ScopyLog.app.warning(
                    "Cleanup failed after settings update: \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        await yieldEvent(.settingsChanged)
    }

    func getSettings() async -> SettingsDTO {
        await settingsStore.load()
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let storage = try requireStorage()
        let count = try await storage.getItemCount()
        let dbSize = await storage.getDatabaseFileSize()
        let externalSize = try await storage.getExternalStorageSizeForStats()
        let thumbnailSize = await storage.getThumbnailCacheSize()
        return (count, dbSize + externalSize + thumbnailSize)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let storage = try requireStorage()
        let count = try await storage.getItemCount()
        let dbSize = await storage.getDatabaseFileSize()
        let externalSize = try await storage.getExternalStorageSizeForStats()
        let thumbnailSize = await storage.getThumbnailCacheSize()
        let dbPath = await storage.databaseFilePath

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
        let storage = try requireStorage()
        guard let item = try await storage.findByID(itemID) else { return nil }
        return await storage.getOriginalImageData(for: item)
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        let storage = try requireStorage()
        return try await storage.getRecentApps(limit: limit)
    }

    // MARK: - Internals

    private func requireMonitor() throws -> ClipboardMonitor {
        guard let monitor else { throw ClipboardServiceError.notStarted }
        return monitor
    }

    private func requireStorage() throws -> StorageService {
        guard let storage else { throw ClipboardServiceError.notStarted }
        return storage
    }

    private func requireSearch() throws -> SearchEngineImpl {
        guard let search else { throw ClipboardServiceError.notStarted }
        return search
    }

    private func getMonitorStream() async -> AsyncStream<ClipboardMonitor.ClipboardContent>? {
        guard let monitor else { return nil }
        return monitor.contentStream
    }

    private func handleNewContent(_ content: ClipboardMonitor.ClipboardContent) async {
        guard let storage, let search else { return }

        if content.type == .image && !settings.saveImages {
            if let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            return
        }
        if content.type == .file && !settings.saveFiles {
            if let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            return
        }

        do {
            let outcome = try await storage.upsertItemWithOutcome(content)
            let storedItem = outcome.item

            await search.handleUpsertedItem(storedItem)
            let dto = await toDTO(storedItem, storage: storage, thumbnailGenerationPriority: .userInitiated)
            switch outcome {
            case .inserted:
                await yieldEvent(.newItem(dto))
            case .updated:
                await yieldEvent(.itemUpdated(dto))
            }

            scheduleCleanup(storage: storage)
        } catch {
            ScopyLog.app.warning("Failed to store clipboard item: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func yieldEvent(_ event: ClipboardEvent) async {
        await eventQueue.enqueue(event)
    }

    private func scheduleCleanup(storage: StorageService) {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(cleanupDebounceDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.runCleanupIfNeeded(storage: storage)
        }
    }

    private func runCleanupIfNeeded(storage: StorageService) async {
        guard !isCleanupRunning else { return }
        isCleanupRunning = true
        defer { isCleanupRunning = false }

        let now = Date()
        let needsFull = now.timeIntervalSince(lastFullCleanupAt) >= fullCleanupInterval
        let needsLight = now.timeIntervalSince(lastLightCleanupAt) >= lightCleanupInterval
        guard needsLight || needsFull else { return }

        let mode: StorageService.CleanupMode = needsFull ? .full : .light
        do {
            try await storage.performCleanup(mode: mode)
            if let search {
                await search.invalidateCache()
            }
            lastLightCleanupAt = now
            if needsFull { lastFullCleanupAt = now }
        } catch {
            ScopyLog.app.warning("Scheduled cleanup failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func toDTO(
        _ item: StorageService.StoredItem,
        storage: StorageService,
        thumbnailGenerationPriority: TaskPriority = .utility
    ) async -> ClipboardItemDTO {
        var thumbnailPath: String? = nil
        if item.type == .image && settings.showImageThumbnails {
            thumbnailPath = await storage.getThumbnailPath(for: item.contentHash)
            if thumbnailPath == nil {
                await scheduleThumbnailGeneration(
                    for: item,
                    storage: storage,
                    priority: thumbnailGenerationPriority
                )
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

    private func scheduleThumbnailGeneration(
        for item: StorageService.StoredItem,
        storage: StorageService,
        priority: TaskPriority = .utility
    ) async {
        let itemID = item.id
        let contentHash = item.contentHash
        let maxHeight = settings.thumbnailHeight

        let externalStorageRoot = storage.externalStorageDirectoryPath
        let thumbnailCacheRoot = storage.thumbnailCacheDirectoryPath

        let storagePath = item.storageRef
        let rawData = item.rawData
        let fallbackImageData: Data?
        if (storagePath == nil || storagePath?.isEmpty == true), rawData == nil {
            fallbackImageData = await storage.getOriginalImageData(for: item)
        } else {
            fallbackImageData = nil
        }

        Task.detached(priority: priority) { [weak self, itemID, contentHash, maxHeight, storagePath, rawData, fallbackImageData, externalStorageRoot, thumbnailCacheRoot] in
            guard let self else { return }

            let shouldGenerate = await ThumbnailGenerationTracker.shared.tryMarkInProgress(contentHash)
            guard shouldGenerate else { return }

            defer {
                Task {
                    await ThumbnailGenerationTracker.shared.markCompleted(contentHash)
                }
            }

            let pngData: Data?
            if let storagePath, !storagePath.isEmpty {
                guard StorageService.validateStorageRef(storagePath, externalStoragePath: externalStorageRoot) else {
                    ScopyLog.app.warning("Thumbnail skipped: invalid storageRef (possible traversal)")
                    return
                }
                pngData = StorageService.makeThumbnailPNG(fromFileAtPath: storagePath, maxHeight: maxHeight)
            } else if let rawData {
                pngData = StorageService.makeThumbnailPNG(from: rawData, maxHeight: maxHeight)
            } else if let fallbackImageData {
                pngData = StorageService.makeThumbnailPNG(from: fallbackImageData, maxHeight: maxHeight)
            } else {
                pngData = nil
            }

            guard let pngData else { return }

            let thumbnailPath = (thumbnailCacheRoot as NSString).appendingPathComponent("\(contentHash).png")
            if !FileManager.default.fileExists(atPath: thumbnailCacheRoot) {
                try? FileManager.default.createDirectory(
                    atPath: thumbnailCacheRoot,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
            do {
                try StorageService.writeAtomically(pngData, to: thumbnailPath)
            } catch {
                ScopyLog.app.warning("Failed to write thumbnail: \(error.localizedDescription, privacy: .private)")
                return
            }

            await self.yieldThumbnailUpdated(itemID: itemID, thumbnailPath: thumbnailPath)
        }
    }

    private func yieldThumbnailUpdated(itemID: UUID, thumbnailPath: String) async {
        guard settings.showImageThumbnails else { return }
        await yieldEvent(.thumbnailUpdated(itemID: itemID, thumbnailPath: thumbnailPath))
    }

}
