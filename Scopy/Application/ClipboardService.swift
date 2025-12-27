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
                storage.cleanupSettings.cleanupImagesOnly = loadedSettings.cleanupImagesOnly
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

        await performClipboardCopy(item: item, monitor: monitor, storage: storage)

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

    private func performClipboardCopy(
        item: StorageService.StoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService
    ) async {
        switch item.type {
        case .text:
            await copyPlainText(item.plainText, monitor: monitor)
        case .rtf, .html, .image:
            await copyRichPayload(item: item, monitor: monitor, storage: storage)
        case .file:
            await copyFilePayload(item: item, monitor: monitor, storage: storage)
        case .other:
            await copyPlainText(item.plainText, monitor: monitor)
        }
    }

    private func copyPlainText(_ text: String, monitor: ClipboardMonitor) async {
        await MainActor.run {
            monitor.copyToClipboard(text: text)
        }
    }

    private func copyRichPayload(
        item: StorageService.StoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService
    ) async {
        let data = await storage.loadPayloadData(for: item)
        guard let data else { return }

        let itemType = item.type
        let pasteboardType: NSPasteboard.PasteboardType
        switch itemType {
        case .rtf: pasteboardType = .rtf
        case .html: pasteboardType = .html
        case .image: pasteboardType = .png
        default: pasteboardType = .string
        }

        await MainActor.run {
            if itemType == .rtf || itemType == .html {
                let plainText = Self.resolvePlainText(for: item, data: data)
                monitor.copyToClipboard(text: plainText, data: data, type: pasteboardType)
            } else {
                monitor.copyToClipboard(data: data, type: pasteboardType)
            }
        }
    }

    private func copyFilePayload(
        item: StorageService.StoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService
    ) async {
        let urlData = await storage.loadPayloadData(for: item)
        if let data = urlData,
           let fileURLs = ClipboardMonitor.deserializeFileURLs(data),
           !fileURLs.isEmpty {
            await MainActor.run {
                monitor.copyToClipboard(fileURLs: fileURLs)
            }
            return
        }

        let paths = item.plainText.components(separatedBy: "\n")
        let fileURLs = paths.compactMap { URL(fileURLWithPath: $0) }
        if !fileURLs.isEmpty {
            await MainActor.run {
                monitor.copyToClipboard(fileURLs: fileURLs)
            }
        } else {
            await copyPlainText(item.plainText, monitor: monitor)
        }
    }

    nonisolated private static func resolvePlainText(for item: StorageService.StoredItem, data: Data) -> String {
        if !item.plainText.isEmpty { return item.plainText }

        switch item.type {
        case .rtf:
            return NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? ""
        case .html:
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html
            ]
            return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string ?? ""
        default:
            return item.plainText
        }
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
                storage.cleanupSettings.cleanupImagesOnly = newSettings.cleanupImagesOnly
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
        let contentSize = try await storage.getTotalSize()
        return (count, contentSize)
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

    func syncExternalImageSizeBytesFromDisk() async throws -> Int {
        let storage = try requireStorage()
        let updated = try await storage.syncExternalImageSizeBytesFromDisk()
        if updated > 0 {
            ScopyLog.storage.info("Synced external image size_bytes from disk: updated=\(updated, privacy: .public)")
        }
        return updated
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        let storage = try requireStorage()
        guard let item = try await storage.findByID(itemID) else { return nil }
        return await storage.loadPayloadData(for: item)
    }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        let storage = try requireStorage()
        guard let item = try await storage.findByID(itemID) else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        guard item.type == .image else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: item.sizeBytes, optimizedBytes: item.sizeBytes)
        }

        let options = PngquantService.Options(
            binaryPath: settings.pngquantBinaryPath,
            qualityMin: settings.pngquantCopyImageQualityMin,
            qualityMax: settings.pngquantCopyImageQualityMax,
            speed: settings.pngquantCopyImageSpeed,
            colors: settings.pngquantCopyImageColors
        )

        if let storageRef = item.storageRef, !storageRef.isEmpty {
            guard StorageService.validateStorageRef(storageRef, externalStoragePath: storage.externalStorageDirectoryPath) else {
                return ImageOptimizationOutcomeDTO(
                    result: .failed(message: "Invalid storageRef"),
                    originalBytes: item.sizeBytes,
                    optimizedBytes: item.sizeBytes
                )
            }

            let url = URL(fileURLWithPath: storageRef)
            let originalBytes = Self.fileSizeBestEffort(url: url) ?? item.sizeBytes
            let backupURL = URL(fileURLWithPath: storageRef + ".scopy-backup-\(UUID().uuidString)")

            do {
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try? FileManager.default.removeItem(at: backupURL)
                }
                try FileManager.default.copyItem(at: url, to: backupURL)

                // Legacy safety: older builds may have stored TIFF (or other) payload under a .png path.
                // Ensure the file is a real PNG before invoking pngquant, otherwise pngquant will hard-fail.
                var didTranscodeToPNG = false
                if !PngquantService.isLikelyPNGFile(url) {
                    didTranscodeToPNG = try await Task.detached(priority: .utility) { () throws -> Bool in
                        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                        guard let pngData = ClipboardMonitor.convertTIFFToPNG(data) else { return false }
                        try StorageService.writeAtomically(pngData, to: url.path)
                        return true
                    }.value
                }

                if !PngquantService.isLikelyPNGFile(url), !didTranscodeToPNG {
                    // Unknown/unsupported image format; keep the original payload.
                    try? FileManager.default.removeItem(at: backupURL)
                    let currentSize = Self.fileSizeBestEffort(url: url) ?? originalBytes
                    return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: originalBytes, optimizedBytes: currentSize)
                }

                let replaced = try await Task.detached(priority: .utility) {
                    try PngquantService.compressPNGFileInPlace(url, options: options)
                }.value

                // If neither transcoding nor pngquant changed the file, return noChange.
                if !replaced, !didTranscodeToPNG {
                    try? FileManager.default.removeItem(at: backupURL)
                    let currentSize = Self.fileSizeBestEffort(url: url) ?? originalBytes
                    return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: originalBytes, optimizedBytes: currentSize)
                }

                let optimizedBytes = Self.fileSizeBestEffort(url: url) ?? originalBytes
                if optimizedBytes >= originalBytes {
                    // Don't keep changes that don't reduce size.
                    if FileManager.default.fileExists(atPath: backupURL.path) {
                        try? FileManager.default.removeItem(at: url)
                        try? FileManager.default.moveItem(at: backupURL, to: url)
                    } else {
                        try? FileManager.default.removeItem(at: backupURL)
                    }
                    return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: originalBytes, optimizedBytes: originalBytes)
                }

                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let newHash = ClipboardMonitor.computeHashStatic(data)

                try await storage.updateItemPayload(
                    id: item.id,
                    contentHash: newHash,
                    sizeBytes: optimizedBytes,
                    storageRef: storageRef,
                    rawData: nil
                )

                if let search {
                    await search.invalidateCache()
                }

                try? FileManager.default.removeItem(at: backupURL)

                let updated = StorageService.StoredItem(
                    id: item.id,
                    type: item.type,
                    contentHash: newHash,
                    plainText: item.plainText,
                    appBundleID: item.appBundleID,
                    createdAt: item.createdAt,
                    lastUsedAt: item.lastUsedAt,
                    useCount: item.useCount,
                    isPinned: item.isPinned,
                    sizeBytes: optimizedBytes,
                    storageRef: storageRef,
                    rawData: nil
                )
                let dto = await toDTO(updated, storage: storage, thumbnailGenerationPriority: .userInitiated)
                await yieldEvent(.itemContentUpdated(dto))

                return ImageOptimizationOutcomeDTO(result: .optimized, originalBytes: originalBytes, optimizedBytes: optimizedBytes)
            } catch {
                // Best-effort restore original file to keep DB/file consistent.
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.moveItem(at: backupURL, to: url)
                } else {
                    try? FileManager.default.removeItem(at: backupURL)
                }

                return ImageOptimizationOutcomeDTO(
                    result: .failed(message: error.localizedDescription),
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }
        }

        if let rawData = item.rawData {
            let originalBytes = rawData.count
            do {
                let compressed = try await Task.detached(priority: .utility) {
                    try PngquantService.compressPNGData(rawData, options: options)
                }.value

                guard compressed != rawData else {
                    return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: originalBytes, optimizedBytes: originalBytes)
                }

                let newHash = ClipboardMonitor.computeHashStatic(compressed)
                let optimizedBytes = compressed.count

                try await storage.updateItemPayload(
                    id: item.id,
                    contentHash: newHash,
                    sizeBytes: optimizedBytes,
                    storageRef: nil,
                    rawData: compressed
                )

                if let search {
                    await search.invalidateCache()
                }

                let updated = StorageService.StoredItem(
                    id: item.id,
                    type: item.type,
                    contentHash: newHash,
                    plainText: item.plainText,
                    appBundleID: item.appBundleID,
                    createdAt: item.createdAt,
                    lastUsedAt: item.lastUsedAt,
                    useCount: item.useCount,
                    isPinned: item.isPinned,
                    sizeBytes: optimizedBytes,
                    storageRef: nil,
                    rawData: compressed
                )
                let dto = await toDTO(updated, storage: storage, thumbnailGenerationPriority: .userInitiated)
                await yieldEvent(.itemContentUpdated(dto))

                return ImageOptimizationOutcomeDTO(result: .optimized, originalBytes: originalBytes, optimizedBytes: optimizedBytes)
            } catch {
                return ImageOptimizationOutcomeDTO(
                    result: .failed(message: error.localizedDescription),
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }
        }

        // Fallback: item has no inline data and no storageRef (unexpected)
        return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: item.sizeBytes, optimizedBytes: item.sizeBytes)
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

    nonisolated private static func fileSizeBestEffort(url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        return size
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

        let preparedContent = await prepareContentForStorage(content)

        do {
            let outcome = try await storage.upsertItemWithOutcome(preparedContent)
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

    private func prepareContentForStorage(
        _ content: ClipboardMonitor.ClipboardContent
    ) async -> ClipboardMonitor.ClipboardContent {
        guard content.type == .image else { return content }
        guard settings.pngquantCopyImageEnabled else { return content }

        let options = PngquantService.Options(
            binaryPath: settings.pngquantBinaryPath,
            qualityMin: settings.pngquantCopyImageQualityMin,
            qualityMax: settings.pngquantCopyImageQualityMax,
            speed: settings.pngquantCopyImageSpeed,
            colors: settings.pngquantCopyImageColors
        )

        switch content.payload {
        case .data(let data):
            let compressed = await Task.detached(priority: .utility) {
                PngquantService.compressBestEffort(data, options: options)
            }.value

            guard compressed != data else { return content }
            let hash = ClipboardMonitor.computeHashStatic(compressed)
            return ClipboardMonitor.ClipboardContent(
                type: content.type,
                plainText: content.plainText,
                payload: .data(compressed),
                appBundleID: content.appBundleID,
                contentHash: hash,
                sizeBytes: compressed.count
            )
        case .file(let url):
            let replaced = await Task.detached(priority: .utility) {
                PngquantService.compressFileBestEffort(url, options: options)
            }.value
            guard replaced else { return content }

            let updatedSize: Int = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int else { return content.sizeBytes }
                return size
            }()

            let updatedHash: String = {
                guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                    return content.contentHash
                }
                return ClipboardMonitor.computeHashStatic(data)
            }()

            return ClipboardMonitor.ClipboardContent(
                type: content.type,
                plainText: content.plainText,
                payload: .file(url),
                appBundleID: content.appBundleID,
                contentHash: updatedHash,
                sizeBytes: updatedSize
            )
        case .none:
            return content
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
            fallbackImageData = await storage.loadPayloadData(for: item)
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
