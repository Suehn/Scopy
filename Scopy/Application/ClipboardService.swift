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

    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?
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

        var continuation: AsyncStream<ClipboardEvent>.Continuation?
        let stream = AsyncStream(
            ClipboardEvent.self,
            bufferingPolicy: .unbounded
        ) { cont in
            continuation = cont
        }
        guard let resolvedContinuation = continuation else {
            fatalError("Failed to create ClipboardService event stream continuation")
        }
        self.eventStream = stream
        self.eventContinuation = resolvedContinuation
    }

    deinit {
        monitorTask?.cancel()
        cleanupTask?.cancel()
        eventContinuation?.finish()
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isStarted else { return }
        isStarted = true

        let pasteboardName = monitorPasteboardName
        let pollingInterval = monitorPollingInterval
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

        self.monitor = monitor
        self.storage = storage
        self.search = search

        try await storage.open()
        try await search.open()

        let loadedSettings = await settingsStore.load()
        settings = loadedSettings

        await MainActor.run {
            storage.cleanupSettings.maxItems = loadedSettings.maxItems
            storage.cleanupSettings.maxSmallStorageMB = loadedSettings.maxStorageMB
        }

        Task { [storage] in
            try? await storage.cleanupOrphanedFiles()
        }

        await MainActor.run {
            monitor.startMonitoring()
        }

        monitorTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = await self.getMonitorStream() else { return }
            for await content in stream {
                guard !Task.isCancelled else { break }
                await self.handleNewContent(content)
            }
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

        if let continuation = eventContinuation {
            eventContinuation = nil
            continuation.finish()
        }

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
        yieldEvent(.itemPinned(itemID))
    }

    func unpin(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.setPin(itemID, pinned: false)
        await search.handlePinnedChange(id: itemID, pinned: false)
        yieldEvent(.itemUnpinned(itemID))
    }

    func delete(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteItem(itemID)
        await search.handleDeletion(id: itemID)
        yieldEvent(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteAllExceptPinned()
        await search.handleClearAll()
        yieldEvent(.itemsCleared(keepPinned: true))
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
            ScopyLog.app.warning("Failed to update item usage stats: \(error.localizedDescription, privacy: .public)")
        }

        await search.handleUpsertedItem(updated)
        yieldEvent(.itemUpdated(await toDTO(updated, storage: storage, thumbnailGenerationPriority: .userInitiated)))
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        let oldHeight = settings.thumbnailHeight
        let oldShowThumbnails = settings.showImageThumbnails

        await settingsStore.save(newSettings)
        settings = newSettings

        if let storage = storage {
            await MainActor.run {
                storage.cleanupSettings.maxItems = newSettings.maxItems
                storage.cleanupSettings.maxSmallStorageMB = newSettings.maxStorageMB
            }

            if oldHeight != newSettings.thumbnailHeight || oldShowThumbnails != newSettings.showImageThumbnails {
                await storage.clearThumbnailCache()
                await MainActor.run {
                    ThumbnailCache.shared.clear()
                }
            }

            do {
                try await storage.performCleanup()
            } catch {
                ScopyLog.app.warning(
                    "Cleanup failed after settings update: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        yieldEvent(.settingsChanged)
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

        if let storagePath = item.storageRef {
            return await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: URL(fileURLWithPath: storagePath), options: [.mappedIfSafe])
            }.value
        }

        if let rawData = item.rawData {
            return rawData
        }

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
                yieldEvent(.newItem(dto))
            case .updated:
                yieldEvent(.itemUpdated(dto))
            }

            scheduleCleanup(storage: storage)
        } catch {
            ScopyLog.app.warning("Failed to store clipboard item: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func yieldEvent(_ event: ClipboardEvent) {
        eventContinuation?.yield(event)
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
            lastLightCleanupAt = now
            if needsFull { lastFullCleanupAt = now }
        } catch {
            ScopyLog.app.warning("Scheduled cleanup failed: \(error.localizedDescription, privacy: .public)")
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
                scheduleThumbnailGeneration(
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
    ) {
        let itemID = item.id
        let contentHash = item.contentHash
        let maxHeight = settings.thumbnailHeight
        let storageRef = storage

        Task.detached(priority: priority) { [weak self] in
            let shouldGenerate = await ThumbnailGenerationTracker.shared.tryMarkInProgress(contentHash)
            guard shouldGenerate else { return }

            defer {
                Task {
                    await ThumbnailGenerationTracker.shared.markCompleted(contentHash)
                }
            }

            let pngData: Data?
            if let storagePath = item.storageRef, !storagePath.isEmpty {
                pngData = StorageService.makeThumbnailPNG(fromFileAtPath: storagePath, maxHeight: maxHeight)
            } else if let rawData = item.rawData {
                pngData = StorageService.makeThumbnailPNG(from: rawData, maxHeight: maxHeight)
            } else if let imageData = await storageRef.getOriginalImageData(for: item) {
                pngData = StorageService.makeThumbnailPNG(from: imageData, maxHeight: maxHeight)
            } else {
                pngData = nil
            }

            guard let pngData else { return }

            guard let thumbnailPath = try? await storageRef.saveThumbnail(pngData, for: contentHash) else { return }
            await self?.yieldThumbnailUpdated(itemID: itemID, thumbnailPath: thumbnailPath)
        }
    }

    private func yieldThumbnailUpdated(itemID: UUID, thumbnailPath: String) {
        guard settings.showImageThumbnails else { return }
        Task { @MainActor in
            ThumbnailCache.shared.remove(path: thumbnailPath)
        }
        yieldEvent(.thumbnailUpdated(itemID: itemID, thumbnailPath: thumbnailPath))
    }
}
