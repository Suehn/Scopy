import AppKit
import Foundation

/// Application 层门面（vNext）：统一组合 monitor/storage/search/settings，并由 actor 持有事件 continuation。
///
/// 说明（Phase 4 约束）：
/// - `ClipboardMonitor` 为 `@MainActor`，该 actor 通过 `MainActor.run {}` 处理边界；`StorageService` 是独立 actor，存储调用不经过主线程。
/// - UI 仍通过 `@MainActor ClipboardServiceProtocol` 调用 `RealClipboardService`（adapter），由 adapter 转发到该 actor。
actor ClipboardBackend {
    // MARK: - Types

    enum ClipboardBackendError: Error, LocalizedError {
        case notStarted
        case itemNotFoundOrSuperseded

        var errorDescription: String? {
            switch self {
            case .notStarted:
                return "ClipboardBackend is not started"
            case .itemNotFoundOrSuperseded:
                return "Clipboard item no longer exists or was superseded"
            }
        }
    }

    enum ImageOptimizationInterlockPoint: Sendable {
        case afterExternalSourceLeaseBeforeValidation
        case afterExternalPayloadCommit
        case afterExternalSourceAdoptionBeforeVerification(attempt: Int)
        case beforeSearchPublication
    }

    enum MetadataPublicationInterlockPoint: Sendable {
        case afterNoteCommit
        case afterNoteDTOConstructionBeforeEvent
        case afterFileSizeCommit
        case afterFileSizeDTOConstructionBeforeEvent
    }

    private enum ExternalSourceReconciliationResult: Sendable {
        case adopted
        case sourceUnavailable
        case failedOrUnstable
    }

    private enum AuthoritativePublicationKind: Sendable {
        case newItem
        case itemUpdated
        case contentUpdated
        case pinState
    }

    struct ImageOptimizationAdmissionSnapshot: Sendable, Equatable {
        let admittedRequestCount: Int
        let activeProcessCount: Int
        let queuedRequestCount: Int
        let requestCapacity: Int
    }

    private struct ThumbnailGenerationKey: Hashable, Sendable {
        let typeNamespace: String
        let contentHash: String
    }

    private struct ThumbnailGenerationWork: Sendable {
        let item: ClipboardStoredItem
        let itemIDs: Set<UUID>
        let maxHeight: Int
        let externalStorageRoot: String
        let thumbnailCacheRoot: String
    }

    private typealias ThumbnailWorkQueue = BoundedCoalescingWorkerQueue<
        ThumbnailGenerationKey,
        ThumbnailGenerationWork,
        String?
    >

    private struct FileSizeComputationWork: Sendable {
        let expected: ClipboardStoredItem
    }

    private struct FileSizeComputationKey: Hashable, Sendable {
        let itemID: UUID
        let typeNamespace: String
        let contentHash: String
        let plainText: String
        let sizeBytes: Int
        let storageRef: String?
        let rawData: Data?

        init(expected: ClipboardStoredItem) {
            self.itemID = expected.id
            self.typeNamespace = expected.type.rawValue
            self.contentHash = expected.contentHash
            self.plainText = expected.plainText
            self.sizeBytes = expected.sizeBytes
            self.storageRef = expected.storageRef
            self.rawData = expected.rawData
        }
    }

    private struct FileSizeComputationResult: Sendable {
        let expected: ClipboardStoredItem
        let fileSizeBytes: Int
    }

    private typealias FileSizeWorkQueue = BoundedCoalescingWorkerQueue<
        FileSizeComputationKey,
        FileSizeComputationWork,
        FileSizeComputationResult?
    >

    // MARK: - Properties

    nonisolated let eventStream: AsyncStream<ClipboardEvent>

    private let databasePath: String?
    private let settingsStore: SettingsStore
    private let monitorPasteboardName: String?
    private let monitorPollingInterval: TimeInterval?
    private let imageOptimizationInterlock: (@Sendable (ImageOptimizationInterlockPoint, UUID) async -> Void)?
    private let metadataPublicationInterlock: (@Sendable (MetadataPublicationInterlockPoint, UUID) async -> Void)?

    private var monitor: ClipboardMonitor?
    private var storage: StorageService?
    private var search: SearchEngineImpl?

    private var settings: SettingsDTO = .default

    struct ThumbnailCacheIndex: Sendable {
        let root: String
        private(set) var filenames: Set<String>

        mutating func pathIfExists(filename: String) -> String? {
            pathIfExists(filename: filename, fileExists: FileManager.default.fileExists(atPath:))
        }

        mutating func pathIfExists(filename: String, fileExists: (String) -> Bool) -> String? {
            guard filenames.contains(filename) else { return nil }

            let path = (root as NSString).appendingPathComponent(filename)
            guard fileExists(path) else {
                filenames.remove(filename)
                return nil
            }
            return path
        }

        mutating func remember(filename: String) {
            filenames.insert(filename)
        }
    }

    private var thumbnailCacheIndex: ThumbnailCacheIndex?
    private var thumbnailCacheIndexTask: Task<Void, Never>?
    private var thumbnailCacheIndexGeneration: UInt64 = 0

    private let eventQueue: ClipboardEventQueue
    private let itemMutationGate = ClipboardItemMutationGate()
    private var monitorTask: Task<Void, Never>?
    private var storageRootLock: StorageRootLock?
    private var memoryPressureSources: [any DispatchSourceMemoryPressure] = []
    private var isStarted = false

    // MARK: - Cleanup Scheduling (v0.26)

    private var cleanupTask: Task<Void, Never>?
    private var isCleanupRunning = false
    private var lastLightCleanupAt: Date = .distantPast
    private var lastFullCleanupAt: Date = .distantPast
    private let lightCleanupInterval: TimeInterval = 60
    private let fullCleanupInterval: TimeInterval = 3600
    private let cleanupDebounceDelay: TimeInterval = 2.0

    // MARK: - File Size Computation

    private let fileSizeComputationRetryInterval: TimeInterval = 3 * 3600
    private let maxConcurrentFileSizeComputations = 2
    private let maxPendingFileSizeComputations = 256
    private var fileSizeComputationQueue: FileSizeWorkQueue?
    private var fileSizeComputationLastAttemptAt = BoundedRetryTimestamps<FileSizeComputationKey>(capacity: 512)

    // MARK: - Thumbnail Generation

    private let maxConcurrentThumbnailGenerations = 2
    private let maxPendingThumbnailGenerations = 128
    private var thumbnailGenerationQueue: ThumbnailWorkQueue?

    // MARK: - Image Optimization

    private let maxActiveImageOptimizationRequests = 6
    private let imageOptimizationPermitPool = AsyncPermitPool(limit: 2, maxPending: 4)
    private var imageOptimizationInProgress = Set<UUID>()

    // MARK: - Initialization

    init(
        databasePath: String? = nil,
        settingsStore: SettingsStore = .shared,
        monitorPasteboardName: String? = nil,
        monitorPollingInterval: TimeInterval? = nil,
        imageOptimizationInterlock: (@Sendable (ImageOptimizationInterlockPoint, UUID) async -> Void)? = nil,
        metadataPublicationInterlock: (@Sendable (MetadataPublicationInterlockPoint, UUID) async -> Void)? = nil
    ) {
        self.databasePath = databasePath
        self.settingsStore = settingsStore
        self.monitorPasteboardName = monitorPasteboardName
        self.monitorPollingInterval = monitorPollingInterval
        self.imageOptimizationInterlock = imageOptimizationInterlock
        self.metadataPublicationInterlock = metadataPublicationInterlock

        let queue = ClipboardEventQueue(capacity: ScopyThresholds.clipboardEventStreamMaxBufferedItems)
        self.eventQueue = queue
        self.eventStream = AsyncStream(unfolding: { await queue.dequeue() })
    }

    deinit {
        monitorTask?.cancel()
        cleanupTask?.cancel()
        if let thumbnailGenerationQueue {
            Task.detached {
                await thumbnailGenerationQueue.stop()
            }
        }
        if let fileSizeComputationQueue {
            Task.detached {
                await fileSizeComputationQueue.stop()
            }
        }
        Task { [eventQueue] in
            await eventQueue.finish()
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isStarted else { return }

        // Claim the storage root before any spool or directory work so a second process
        // cannot orphan-sweep payloads or double-capture the pasteboard.
        let databasePath = databasePath
        let storageRoot = StorageService.resolveRootDirectory(databasePath: databasePath, storageRootURL: nil)
        let rootLock = try StorageRootLock.acquire(root: storageRoot)

        let loadedSettings = await settingsStore.load()

        let pasteboardName = monitorPasteboardName
        let pollingInterval = monitorPollingInterval ?? (TimeInterval(loadedSettings.clipboardPollingIntervalMs) / 1000.0)
        let storage = StorageService(databasePath: databasePath, storageRootURL: storageRoot)
        let ingestSpoolDirectory = URL(
            fileURLWithPath: storage.ingestSpoolDirectoryPath,
            isDirectory: true
        )
        let legacyIngestSpoolDirectory = databasePath == nil
            ? ClipboardMonitor.defaultLegacyIngestSpoolDirectory()
            : nil

        await Task.detached(priority: .utility) {
            ClipboardMonitor.prepareIngestSpoolDirectory(
                ingestSpoolDirectory,
                legacyDirectory: legacyIngestSpoolDirectory
            )
            Self.sweepStaleShareableImages()
        }.value

        let monitor = await MainActor.run {
            let pasteboard: NSPasteboard
            if let pasteboardName, !pasteboardName.isEmpty {
                pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            } else {
                pasteboard = .general
            }
            return ClipboardMonitor(
                pasteboard: pasteboard,
                pollingInterval: pollingInterval,
                ingestSpoolDirectory: ingestSpoolDirectory,
                legacyIngestSpoolDirectory: legacyIngestSpoolDirectory,
                spoolAlreadyPrepared: true
            )
        }

        let search = SearchEngineImpl(dbPath: storage.databaseFilePath, commitJournal: storage.commitJournal)

        do {
            try await storage.open()
            try await search.open()

            var deferredTerminalIngestIDs = Set<UUID>()
            while true {
                let excludedIDs = deferredTerminalIngestIDs
                let terminalAcknowledgements = await MainActor.run {
                    monitor.pendingTerminalIngestAcknowledgements(
                        limit: 256,
                        excluding: excludedIDs
                    )
                }
                guard !terminalAcknowledgements.isEmpty else { break }
                for acknowledgement in terminalAcknowledgements {
                    do {
                        try await storage.removeIngestReceipt(acknowledgement.ingestID)
                        let completed = await MainActor.run {
                            monitor.completeTerminalIngestAcknowledgement(acknowledgement)
                        }
                        if !completed {
                            deferredTerminalIngestIDs.insert(acknowledgement.ingestID)
                        }
                    } catch {
                        deferredTerminalIngestIDs.insert(acknowledgement.ingestID)
                        ScopyLog.app.warning(
                            "Failed to finish terminal ingest recovery: \(error.localizedDescription, privacy: .private)"
                        )
                    }
                }
                await Task.yield()
            }

            await MainActor.run {
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
            self.storageRootLock = rootLock
            self.isStarted = true
            startMemoryPressureMonitoring()

            await startBackgroundMediaQueuesIfNeeded()

            scheduleThumbnailCacheIndexBuildIfNeeded(thumbnailCacheRoot: storage.thumbnailCacheDirectoryPath)

            Task { [storage] in
                try? await storage.cleanupOrphanedFiles()
            }
        } catch {
            await MainActor.run {
                monitor.stopMonitoring()
            }
            await storage.close()
            await search.close()
            rootLock.release()
            throw error
        }
    }

    /// Warning releases search session memory; critical also drops the short-query index and
    /// SQLite's page cache on the write connection.
    private func startMemoryPressureMonitoring() {
        memoryPressureSources = [false, true].map { critical in
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: critical ? .critical : .warning,
                queue: .global(qos: .utility)
            )
            let handler: @Sendable () -> Void = { [weak self] in
                Task { await self?.handleMemoryPressure(critical: critical) }
            }
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }

    private func handleMemoryPressure(critical: Bool) async {
        await search?.trimSessionMemory(critical ? .memoryCritical : .memoryWarning)
        if critical {
            await storage?.repository.releaseMemory()
        }
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false

        let monitor = monitor
        let storage = storage
        let search = search
        let rootLock = storageRootLock
        storageRootLock = nil
        memoryPressureSources.forEach { $0.cancel() }
        memoryPressureSources = []

        await stopBackgroundMediaQueues()

        self.monitor = nil
        self.storage = nil
        self.search = nil
        thumbnailCacheIndex = nil

        thumbnailCacheIndexTask?.cancel()
        thumbnailCacheIndexTask = nil

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

        rootLock?.release()
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

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        let storage = try requireStorage()
        let items = try await storage.fetchPinned()
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let storage = try requireStorage()
        let items = try await storage.fetchRecentUnpinned(limit: limit, offset: offset)
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

        var hits: [SearchResultHit] = []
        hits.reserveCapacity(result.items.count)
        for item in result.items {
            try Task.checkCancellation()
            let matchContext = result.matchContexts[item.id]
            let dto = await toDTO(item, storage: storage)
            hits.append(SearchResultHit(item: dto, matchContext: matchContext))
        }

        return SearchResultPage(
            hits: hits,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage
        )
    }

    func pin(itemID: UUID) async throws {
        try await setPinned(itemID: itemID, pinned: true)
    }

    func unpin(itemID: UUID) async throws {
        try await setPinned(itemID: itemID, pinned: false)
    }

    private func setPinned(itemID: UUID, pinned: Bool) async throws {
        let storage = try requireStorage()
        _ = try requireSearch()
        guard let lease = await itemMutationGate.acquire(itemID: itemID) else {
            throw CancellationError()
        }

        do {
            guard !Task.isCancelled else { throw CancellationError() }
            try await storage.setPin(itemID, pinned: pinned)
            _ = await publishAuthoritativeItemState(
                id: itemID,
                storage: storage,
                priority: .userInitiated,
                kind: .pinState
            )
            await itemMutationGate.release(lease)
        } catch {
            await itemMutationGate.release(lease)
            throw error
        }
    }

    func updateNote(itemID: UUID, note: String?) async throws {
        let storage = try requireStorage()
        _ = try requireSearch()

        guard let existing = try await storage.findByID(itemID) else {
            throw ClipboardBackendError.itemNotFoundOrSuperseded
        }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard existing.note != normalized else { return }

        guard try await storage.updateNote(id: itemID, note: normalized) != nil else {
            throw ClipboardBackendError.itemNotFoundOrSuperseded
        }
        await metadataPublicationInterlock?(.afterNoteCommit, itemID)
        _ = await publishAuthoritativeItemState(
            id: itemID,
            storage: storage,
            priority: .userInitiated,
            metadataInterlockPoint: .afterNoteDTOConstructionBeforeEvent
        )
    }

    func delete(itemID: UUID) async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteItem(itemID)
        await search.applyCommittedChanges()
        fileSizeComputationLastAttemptAt.remove { $0.itemID == itemID }
        await fileSizeComputationQueue?.cancelPending { $0.itemID == itemID }
        let publication = await reservePublication(for: itemID)
        await yieldEvent(.itemDeleted(itemID), publication: publication)
    }

    func clearAll() async throws {
        let storage = try requireStorage()
        let search = try requireSearch()

        try await storage.deleteAllExceptPinned()
        await search.applyCommittedChanges()
        fileSizeComputationLastAttemptAt.removeAll()
        await fileSizeComputationQueue?.discardPending()
        await thumbnailGenerationQueue?.discardPending()
        await eventQueue.advanceClearGeneration()
        await yieldEvent(.itemsCleared(keepPinned: true))
    }

    func copyToClipboard(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID, imageWriteMode: .standard)
    }

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID, imageWriteMode: .codexOptimized)
    }

    func fileURLs(itemID: UUID) async throws -> [URL] {
        let storage = try requireStorage()
        guard let item = try await storage.findByID(itemID) else { return [] }
        let originalURLs = await resolvedFileURLs(for: item, storage: storage)
        if !originalURLs.isEmpty {
            return originalURLs
        }

        if item.type == .image,
           let shareableURL = await shareableImageFileURL(for: item, storage: storage) {
            return [shareableURL]
        }

        return []
    }

    private func copyToClipboard(
        itemID: UUID,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        let monitor = try requireMonitor()
        let storage = try requireStorage()
        _ = try requireSearch()

        guard let item = try await storage.findByID(itemID) else {
            throw ClipboardCopyError.itemNotFound(itemID)
        }

        // Usage stats and the item event describe a copy that happened. Nothing below this line
        // runs unless the pasteboard actually took the content.
        try await performClipboardCopy(
            item: item,
            monitor: monitor,
            storage: storage,
            imageWriteMode: imageWriteMode
        )

        do {
            _ = try await storage.incrementUsage(id: item.id, at: Date())
        } catch {
            ScopyLog.app.warning("Failed to update item usage stats: \(error.localizedDescription, privacy: .private)")
        }

        _ = await publishAuthoritativeItemState(
            id: item.id,
            storage: storage,
            priority: .userInitiated,
            kind: .itemUpdated
        )
    }

    private func performClipboardCopy(
        item: ClipboardStoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        switch item.type {
        case .text, .other:
            try await copyPlainText(item.plainText, itemID: item.id, monitor: monitor)
        case .rtf, .html, .image:
            try await copyRichPayload(item: item, monitor: monitor, storage: storage, imageWriteMode: imageWriteMode)
        case .file:
            try await copyFilePayload(item: item, monitor: monitor, storage: storage, imageWriteMode: imageWriteMode)
        }
    }

    private func copyPlainText(
        _ text: String,
        itemID: UUID,
        monitor: ClipboardMonitor
    ) async throws {
        try await MainActor.run {
            do {
                try monitor.copyToClipboard(text: text)
            } catch {
                throw ClipboardCopyError.pasteboardRejectedContent(itemID)
            }
        }
    }

    private func copyRichPayload(
        item: ClipboardStoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        let data = await storage.loadPayloadData(for: item)
        guard let data else {
            throw ClipboardCopyError.payloadUnavailable(item.id)
        }

        let itemType = item.type
        let pasteboardType: NSPasteboard.PasteboardType
        switch itemType {
        case .rtf: pasteboardType = .rtf
        case .html: pasteboardType = .html
        case .image: pasteboardType = .png
        default: pasteboardType = .string
        }

        let itemID = item.id
        try await MainActor.run {
            do {
                if itemType == .rtf || itemType == .html {
                    let plainText = Self.resolvePlainText(for: item, data: data)
                    try monitor.copyToClipboard(text: plainText, data: data, type: pasteboardType)
                } else if itemType == .image,
                          imageWriteMode == .standard,
                          let fileURL = Self.managedImageFileURL(for: item, storage: storage) {
                    try monitor.copyToClipboard(imageData: data, fileURL: fileURL, imageWriteMode: imageWriteMode)
                } else {
                    try monitor.copyToClipboard(data: data, type: pasteboardType, imageWriteMode: imageWriteMode)
                }
            } catch ClipboardMonitor.PasteboardWriteFailure.imageNotRenderable {
                throw ClipboardCopyError.imageNotRenderable(itemID)
            } catch {
                throw ClipboardCopyError.pasteboardRejectedContent(itemID)
            }
        }
    }

    private func copyFilePayload(
        item: ClipboardStoredItem,
        monitor: ClipboardMonitor,
        storage: StorageService,
        imageWriteMode: ClipboardMonitor.ImagePasteboardWriteMode
    ) async throws {
        let fileURLs = await resolvedFileURLs(for: item, storage: storage)
        // Every recorded node is gone; the path text is all that is left to hand back.
        guard !fileURLs.isEmpty else {
            try await copyPlainText(item.plainText, itemID: item.id, monitor: monitor)
            return
        }

        let itemID = item.id
        try await MainActor.run {
            do {
                if let pngData = Self.resolvePNGDataForTemporaryImageFileURLs(fileURLs) {
                    try monitor.copyToClipboard(data: pngData, type: .png, imageWriteMode: imageWriteMode)
                } else {
                    try monitor.copyToClipboard(fileURLs: fileURLs)
                }
            } catch ClipboardMonitor.PasteboardWriteFailure.imageNotRenderable {
                throw ClipboardCopyError.imageNotRenderable(itemID)
            } catch {
                throw ClipboardCopyError.pasteboardRejectedContent(itemID)
            }
        }
    }

    nonisolated private static func managedImageFileURL(
        for item: ClipboardStoredItem,
        storage: StorageService
    ) -> URL? {
        guard item.type == .image,
              let storageRef = item.storageRef,
              !storageRef.isEmpty,
              StorageService.validateStorageRef(storageRef, externalStoragePath: storage.externalStorageDirectoryPath) else {
            return nil
        }

        let url = URL(fileURLWithPath: storageRef)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func resolvedFileURLs(for item: ClipboardStoredItem, storage: StorageService) async -> [URL] {
        if item.type == .file || item.type == .image {
            let urlData = await storage.loadPayloadData(for: item)
            if let data = urlData,
               let fileURLs = Self.deserializeExistingFileURLs(data),
               !fileURLs.isEmpty {
                return fileURLs
            }
        }

        // A managed external payload is always a regular file Scopy wrote itself.
        if let storageRef = item.storageRef,
           !storageRef.isEmpty,
           FilePreviewSupport.accepts(URL(fileURLWithPath: storageRef), policy: .regularFilesOnly) {
            return [URL(fileURLWithPath: storageRef)]
        }

        return FilePreviewSupport.fileURLs(from: item.plainText)
    }

    /// Restores the exact node list a file capture recorded, in copy order. Directories and
    /// packages are part of that list: Finder copies them as plain file URLs, and dropping them
    /// here is what makes a copied folder replay as its path text instead of the folder itself.
    private static func deserializeExistingFileURLs(_ data: Data) -> [URL]? {
        guard let paths = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let urls = paths.compactMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let url = URL(fileURLWithPath: trimmed)
            guard FilePreviewSupport.accepts(url, policy: .anyExistingNode) else { return nil }
            return url
        }
        return urls.isEmpty ? nil : urls
    }

    private func shareableImageFileURL(for item: ClipboardStoredItem, storage: StorageService) async -> URL? {
        if let payloadData = await storage.loadPayloadData(for: item),
           let imagePayload = ClipboardMonitor.makeImagePasteboardPayloadForWrite(payloadData, imageWriteMode: .standard) {
            return await writeShareableImagePNG(imagePayload.primaryPNGData, for: item)
        }

        let thumbnailPath = (storage.thumbnailCacheDirectoryPath as NSString)
            .appendingPathComponent("\(item.contentHash).png")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: thumbnailPath, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return URL(fileURLWithPath: thumbnailPath)
        }

        return nil
    }

    /// Temporary PNGs handed to `NSSharingService`. One file per item id, so repeated shares of
    /// the same item reuse a slot instead of accumulating.
    nonisolated static var shareableImageDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Scopy", isDirectory: true)
            .appendingPathComponent("AirDrop", isDirectory: true)
    }

    private func writeShareableImagePNG(_ data: Data, for item: ClipboardStoredItem) async -> URL? {
        await Task.detached(priority: .utility) {
            let directory = Self.shareableImageDirectory
            let url = directory.appendingPathComponent("scopy-image-\(item.id.uuidString).png")

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try StorageService.writeAtomically(data, to: url.path)
                return url
            } catch {
                ScopyLog.app.warning("Failed to prepare image for AirDrop: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }.value
    }

    /// Shares outlive the sharing sheet by an unbounded amount, so the files cannot be deleted on
    /// completion. Sweeping them at startup bounds the directory without racing an active share.
    nonisolated private static func sweepStaleShareableImages() {
        let directory = shareableImageDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    nonisolated private static func resolvePlainText(for item: ClipboardStoredItem, data: Data) -> String {
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

    nonisolated private static func resolvePNGDataForTemporaryImageFileURLs(_ fileURLs: [URL]) -> Data? {
        guard fileURLs.count == 1 else { return nil }
        return ClipboardMonitor.loadImageFileDataAsPNG(fileURLs[0])
    }

    private func cleanupPolicy() -> StorageService.CleanupPolicy {
        var policy = StorageService.CleanupPolicy()
        policy.maxItems = settings.maxItems
        policy.maxContentBytes = settings.maxStorageMB * 1024 * 1024
        policy.imagesOnly = settings.cleanupImagesOnly
        return policy
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        let oldSettings = settings
        let patch = SettingsPatch.from(baseline: oldSettings, draft: newSettings)
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
            if patch.affectsThumbnailCache {
                await stopThumbnailGenerationQueue()
                invalidateThumbnailCacheIndex()
                await storage.clearThumbnailCache()
                invalidateThumbnailCacheIndex()
                await startThumbnailGenerationQueueIfNeeded()
            }

            if patch.requiresStorageCleanup {
                do {
                    _ = try await storage.performCleanup(
                        mode: .full,
                        policy: cleanupPolicy(),
                        onCommitted: cleanupCommitHandler()
                    )
                } catch {
                    ScopyLog.app.warning(
                        "Cleanup failed after settings update: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        await yieldEvent(.settingsChanged)
    }

    func getSettings() async -> SettingsDTO {
        await settingsStore.load()
    }

    func setCleanupInterlockForTesting(
        _ interlock: (@Sendable (StorageService.CleanupInterlockPoint) async -> Void)?
    ) async {
        await storage?.setCleanupInterlockForTesting(interlock)
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
        let dbSize = storage.getDatabaseFileSize()
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

    func syncExternalImageSizeBytesFromDisk() async throws -> Int {
        let storage = try requireStorage()
        let updated = try await storage.syncExternalImageSizeBytesFromDisk()
        if updated > 0 {
            await search?.applyCommittedChanges()
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
        guard !Task.isCancelled else {
            return Self.cancelledImageOptimizationOutcome(originalBytes: 0)
        }
        guard !imageOptimizationInProgress.contains(itemID) else {
            return Self.busyImageOptimizationOutcome(
                message: "Image optimization is already running for this item"
            )
        }
        guard imageOptimizationInProgress.count < maxActiveImageOptimizationRequests else {
            return Self.busyImageOptimizationOutcome(message: "Image optimization queue is busy")
        }

        imageOptimizationInProgress.insert(itemID)
        defer {
            imageOptimizationInProgress.remove(itemID)
        }

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

        guard await imageOptimizationPermitPool.acquire() else {
            if Task.isCancelled {
                return Self.cancelledImageOptimizationOutcome(originalBytes: item.sizeBytes)
            }
            return Self.busyImageOptimizationOutcome(message: "Image optimization queue is busy")
        }
        guard !Task.isCancelled else {
            await imageOptimizationPermitPool.release()
            return Self.cancelledImageOptimizationOutcome(originalBytes: item.sizeBytes)
        }

        let outcome: ImageOptimizationOutcomeDTO
        if let storageRef = item.storageRef, !storageRef.isEmpty {
            outcome = await optimizeExternalImage(
                item,
                storageRef: storageRef,
                storage: storage,
                options: options
            )
        } else if let rawData = item.rawData {
            outcome = await optimizeInlineImage(
                item,
                rawData: rawData,
                storage: storage,
                options: options
            )
        } else {
            // Fallback: item has no inline data and no storageRef (unexpected)
            outcome = ImageOptimizationOutcomeDTO(
                result: .noChange,
                originalBytes: item.sizeBytes,
                optimizedBytes: item.sizeBytes
            )
        }
        await imageOptimizationPermitPool.release()
        return outcome
    }

    func imageOptimizationAdmissionSnapshot() async -> ImageOptimizationAdmissionSnapshot {
        let permitSnapshot = await imageOptimizationPermitPool.snapshot()
        return ImageOptimizationAdmissionSnapshot(
            admittedRequestCount: imageOptimizationInProgress.count,
            activeProcessCount: permitSnapshot.activeCount,
            queuedRequestCount: permitSnapshot.queuedCount,
            requestCapacity: maxActiveImageOptimizationRequests
        )
    }

    private func optimizeInlineImage(
        _ item: ClipboardStoredItem,
        rawData: Data,
        storage: StorageService,
        options: PngquantService.Options
    ) async -> ImageOptimizationOutcomeDTO {
        let originalBytes = rawData.count
        do {
            let compressionTask = Task.detached(priority: .utility) {
                try PngquantService.compressPNGData(rawData, options: options)
            }
            let compressed = try await withTaskCancellationHandler(operation: {
                try await compressionTask.value
            }, onCancel: {
                compressionTask.cancel()
            })

            guard compressed != rawData else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }
            guard !Task.isCancelled else {
                return Self.cancelledImageOptimizationOutcome(originalBytes: originalBytes)
            }

            let newHash = ClipboardMonitor.computeHashStatic(compressed)
            let optimizedBytes = compressed.count
            guard let updated = try await storage.compareAndSwapItemPayload(
                expected: item,
                contentHash: newHash,
                sizeBytes: optimizedBytes,
                storageRef: nil,
                rawData: compressed
            ) else {
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
            guard let published = await publishOptimizedItem(updated, storage: storage),
                  Self.hasSamePayload(published, as: updated) else {
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
            return ImageOptimizationOutcomeDTO(
                result: .optimized,
                originalBytes: originalBytes,
                optimizedBytes: optimizedBytes,
                resultingContentHash: newHash
            )
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: originalBytes,
                optimizedBytes: originalBytes
            )
        }
    }

    private func optimizeExternalImage(
        _ item: ClipboardStoredItem,
        storageRef: String,
        storage: StorageService,
        options: PngquantService.Options
    ) async -> ImageOptimizationOutcomeDTO {
        guard StorageService.validateStorageRef(
            storageRef,
            externalStoragePath: storage.externalStorageDirectoryPath
        ) else {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: "Invalid storageRef"),
                originalBytes: item.sizeBytes,
                optimizedBytes: item.sizeBytes
            )
        }

        let sourceURL = URL(fileURLWithPath: storageRef)
        // Hidden staging files are skipped by full orphan enumeration. The storage commit moves
        // this complete payload to a new random managed path immediately before CAS.
        let stagedURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".scopy-optimize-\(UUID().uuidString).stage"
        )
        defer {
            try? FileManager.default.removeItem(at: stagedURL)
        }

        var originalBytes = max(0, item.sizeBytes)
        do {
            let stagedOriginalData = try await Task.detached(priority: .utility) { () throws -> Data in
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                return try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
            }.value
            originalBytes = stagedOriginalData.count
            // External payload bytes may legitimately have been edited out of band while the DB
            // hash remains stale. Fingerprint the bytes actually staged instead of assuming the
            // persisted content hash is current.
            let sourceFingerprint = ClipboardMonitor.computeHashStatic(stagedOriginalData)

            var didTranscodeToPNG = false
            if !PngquantService.isLikelyPNG(stagedOriginalData) {
                didTranscodeToPNG = try await Task.detached(priority: .utility) { () throws -> Bool in
                    guard let pngData = ClipboardMonitor.convertTIFFToPNG(stagedOriginalData) else {
                        return false
                    }
                    try StorageService.writeAtomically(pngData, to: stagedURL.path)
                    return true
                }.value
            }

            guard PngquantService.isLikelyPNGFile(stagedURL) else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }

            let compressionTask = Task.detached(priority: .utility) {
                try PngquantService.compressPNGFileInPlace(stagedURL, options: options)
            }
            let replaced = try await withTaskCancellationHandler(operation: {
                try await compressionTask.value
            }, onCancel: {
                compressionTask.cancel()
            })
            guard replaced || didTranscodeToPNG else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }

            let optimizedData = try await Task.detached(priority: .utility) {
                try Data(contentsOf: stagedURL, options: [.mappedIfSafe])
            }.value
            let optimizedBytes = optimizedData.count
            guard optimizedBytes < originalBytes else {
                return ImageOptimizationOutcomeDTO(
                    result: .noChange,
                    originalBytes: originalBytes,
                    optimizedBytes: originalBytes
                )
            }
            guard !Task.isCancelled else {
                return Self.cancelledImageOptimizationOutcome(originalBytes: originalBytes)
            }

            let newHash = ClipboardMonitor.computeHashStatic(optimizedData)
            let stableOriginalBytes = originalBytes
            let leasedOutcome = await storage.withExternalImageSourceLease(
                sourceURL: sourceURL
            ) { [self] sourceLease in
                await commitOptimizedExternalImageUnderLease(
                    item: item,
                    sourceURL: sourceURL,
                    stagedURL: stagedURL,
                    stagedOriginalData: stagedOriginalData,
                    sourceFingerprint: sourceFingerprint,
                    optimizedBytes: optimizedBytes,
                    newHash: newHash,
                    originalBytes: stableOriginalBytes,
                    storage: storage,
                    sourceLease: sourceLease
                )
            }
            return leasedOutcome ?? Self.supersededImageOptimizationOutcome(originalBytes: stableOriginalBytes)
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: originalBytes,
                optimizedBytes: originalBytes
            )
        }
    }

    private func commitOptimizedExternalImageUnderLease(
        item: ClipboardStoredItem,
        sourceURL: URL,
        stagedURL: URL,
        stagedOriginalData: Data,
        sourceFingerprint: String,
        optimizedBytes: Int,
        newHash: String,
        originalBytes: Int,
        storage: StorageService,
        sourceLease: StorageService.ExternalImageSourceLease
    ) async -> ImageOptimizationOutcomeDTO {
        await imageOptimizationInterlock?(.afterExternalSourceLeaseBeforeValidation, item.id)
        let liveSourceStillMatches = await externalSourceMatches(
            sourceURL,
            expectedData: stagedOriginalData,
            expectedFingerprint: sourceFingerprint
        )
        guard liveSourceStillMatches, !Task.isCancelled else {
            return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
        }

        let updated: ClipboardStoredItem
        do {
            guard let value = try await storage.commitOptimizedExternalImagePayload(
                expected: item,
                stagedURL: stagedURL,
                contentHash: newHash,
                sizeBytes: optimizedBytes
            ) else {
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
            updated = value
        } catch {
            return ImageOptimizationOutcomeDTO(
                result: .failed(message: error.localizedDescription),
                originalBytes: originalBytes,
                optimizedBytes: originalBytes
            )
        }

        await imageOptimizationInterlock?(.afterExternalPayloadCommit, item.id)
        let postCommitSourceMatches = await externalSourceMatches(
            sourceURL,
            expectedData: stagedOriginalData,
            expectedFingerprint: sourceFingerprint
        )
        if !postCommitSourceMatches {
            let reconciliation = await reconcileExternalSourceOwnership(
                sourceURL: sourceURL,
                committedItem: updated,
                storage: storage,
                sourceLease: sourceLease
            )

            switch reconciliation {
            case .sourceUnavailable:
                    let current = try? await storage.findByID(item.id)
                    guard let current,
                          Self.hasSamePayload(current, as: updated) else {
                        _ = await publishAuthoritativeItemState(
                            id: item.id,
                            storage: storage,
                            priority: .userInitiated
                        )
                        return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
                    }
                case .adopted, .failedOrUnstable:
                    _ = await publishAuthoritativeItemState(
                        id: item.id,
                        storage: storage,
                        priority: .userInitiated
                    )
                    return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
                }
        }

        guard let published = await publishOptimizedItem(updated, storage: storage),
              Self.hasSamePayload(published, as: updated) else {
            return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
        }
        return ImageOptimizationOutcomeDTO(
            result: .optimized,
            originalBytes: originalBytes,
            optimizedBytes: optimizedBytes,
            resultingContentHash: newHash
        )
    }

    private func publishOptimizedItem(
        _ updated: ClipboardStoredItem,
        storage: StorageService
    ) async -> ClipboardStoredItem? {
        await imageOptimizationInterlock?(.beforeSearchPublication, updated.id)
        guard let current = await publishAuthoritativeItemState(
            id: updated.id,
            storage: storage,
            priority: .userInitiated
        ), Self.hasSamePayload(current, as: updated) else {
            return nil
        }
        return current
    }

    @discardableResult
    private func publishAuthoritativeItemState(
        id: UUID,
        storage: StorageService,
        priority: TaskPriority,
        kind: AuthoritativePublicationKind = .contentUpdated,
        metadataInterlockPoint: MetadataPublicationInterlockPoint? = nil
    ) async -> ClipboardStoredItem? {
        let publication = await reservePublication(for: id)
        guard let current = await synchronizeSearchWithCurrentItem(id: id, storage: storage) else {
            let latest: ClipboardStoredItem?
            do {
                latest = try await storage.findByID(id)
            } catch {
                await eventQueue.discardPublication(publication)
                return nil
            }
            guard latest == nil else {
                await eventQueue.discardPublication(publication)
                return nil
            }
            let accepted = await yieldEvent(.itemDeleted(id), publication: publication)
            guard accepted else { return nil }
            return nil
        }

        let event: ClipboardEvent
        switch kind {
        case .newItem:
            let dto = await toDTO(
                current,
                storage: storage,
                thumbnailGenerationPriority: priority
            )
            event = .newItem(dto)
        case .itemUpdated:
            let dto = await toDTO(
                current,
                storage: storage,
                thumbnailGenerationPriority: priority
            )
            event = .itemUpdated(dto)
        case .contentUpdated:
            let dto = await toDTO(
                current,
                storage: storage,
                thumbnailGenerationPriority: priority
            )
            event = .itemContentUpdated(dto)
        case .pinState:
            event = current.isPinned ? .itemPinned(id) : .itemUnpinned(id)
        }
        if let metadataInterlockPoint {
            await metadataPublicationInterlock?(metadataInterlockPoint, id)
        }
        let accepted = await yieldEvent(event, publication: publication)
        guard accepted else { return nil }
        return current
    }

    /// Applies committed storage changes to search before the item is published, so a search
    /// issued after the event sees it, then returns the item's current row (nil when it no longer
    /// exists or cannot be read).
    private func synchronizeSearchWithCurrentItem(
        id: UUID,
        storage: StorageService
    ) async -> ClipboardStoredItem? {
        await search?.applyCommittedChanges()
        return try? await storage.findByID(id)
    }

    private func externalSourceMatches(
        _ sourceURL: URL,
        expectedData: Data,
        expectedFingerprint: String
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let liveData = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]) else {
                return false
            }
            return liveData.count == expectedData.count &&
                ClipboardMonitor.computeHashStatic(liveData) == expectedFingerprint
        }.value
    }

    /// If an uncooperative external writer changes the source during the commit window, return
    /// DB ownership to that live source only while the just-committed payload is still the winner.
    /// Re-read and advance the fingerprint a few times so a second in-place write does not leave
    /// the row describing bytes that were already superseded.
    private func reconcileExternalSourceOwnership(
        sourceURL: URL,
        committedItem: ClipboardStoredItem,
        storage: StorageService,
        sourceLease: StorageService.ExternalImageSourceLease
    ) async -> ExternalSourceReconciliationResult {
        let result = await storage.reconcileExternalImageSourceOwnership(
            committedItem: committedItem,
            sourceURL: sourceURL,
            sourceLease: sourceLease,
            verificationInterlock: { [imageOptimizationInterlock] attempt in
                await imageOptimizationInterlock?(
                    .afterExternalSourceAdoptionBeforeVerification(attempt: attempt),
                    committedItem.id
                )
            }
        )
        switch result {
        case .adopted:
            return .adopted
        case .sourceUnavailable:
            return .sourceUnavailable
        case .failedOrUnstable:
            return .failedOrUnstable
        }
    }

    private static func hasSamePayload(
        _ lhs: ClipboardStoredItem,
        as rhs: ClipboardStoredItem
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.type == rhs.type &&
            lhs.contentHash == rhs.contentHash &&
            lhs.plainText == rhs.plainText &&
            lhs.sizeBytes == rhs.sizeBytes &&
            lhs.fileSizeBytes == rhs.fileSizeBytes &&
            lhs.storageRef == rhs.storageRef &&
            lhs.rawData == rhs.rawData
    }

    private static func supersededImageOptimizationOutcome(
        originalBytes: Int
    ) -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(
            result: .failed(message: "Image changed while optimization was running"),
            originalBytes: originalBytes,
            optimizedBytes: originalBytes
        )
    }

    private static func cancelledImageOptimizationOutcome(
        originalBytes: Int
    ) -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(
            result: .failed(message: "Image optimization was cancelled"),
            originalBytes: originalBytes,
            optimizedBytes: originalBytes
        )
    }

    private static func busyImageOptimizationOutcome(
        message: String
    ) -> ImageOptimizationOutcomeDTO {
        ImageOptimizationOutcomeDTO(
            result: .failed(message: message),
            originalBytes: 0,
            optimizedBytes: 0
        )
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        let storage = try requireStorage()
        return try await storage.getRecentApps(limit: limit)
    }

    // MARK: - Internals

    private func requireMonitor() throws -> ClipboardMonitor {
        guard let monitor else { throw ClipboardBackendError.notStarted }
        return monitor
    }

    private func requireStorage() throws -> StorageService {
        guard let storage else { throw ClipboardBackendError.notStarted }
        return storage
    }

    private func requireSearch() throws -> SearchEngineImpl {
        guard let search else { throw ClipboardBackendError.notStarted }
        return search
    }

    private func getMonitorStream() async -> AsyncStream<ClipboardMonitor.ClipboardContent>? {
        guard let monitor else { return nil }
        return monitor.contentStream
    }

    private func handleNewContent(_ content: ClipboardMonitor.ClipboardContent) async {
        guard let storage, search != nil else { return }

        if content.type == .image && !settings.saveImages {
            if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            await acknowledgeIngestEnvelopeIfNeeded(content, storage: storage)
            return
        }
        if content.type == .file && !settings.saveFiles {
            if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            await acknowledgeIngestEnvelopeIfNeeded(content, storage: storage)
            return
        }

        let preparedContent = await prepareContentForStorage(content)

        do {
            let outcome = try await storage.upsertItemWithOutcome(preparedContent)
            switch outcome {
            case .inserted(let storedItem):
                _ = await publishAuthoritativeItemState(
                    id: storedItem.id,
                    storage: storage,
                    priority: .userInitiated,
                    kind: .newItem
                )
            case .updated(let storedItem):
                _ = await publishAuthoritativeItemState(
                    id: storedItem.id,
                    storage: storage,
                    priority: .userInitiated,
                    kind: .itemUpdated
                )
            case .alreadyApplied:
                break
            }

            await acknowledgeIngestEnvelopeIfNeeded(preparedContent, storage: storage)
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
                note: content.note,
                appBundleID: content.appBundleID,
                contentHash: hash,
                sizeBytes: compressed.count,
                fileSizeBytes: content.fileSizeBytes,
                ingestEnvelopeURL: content.ingestEnvelopeURL,
                ingestID: content.ingestID,
                fileOwnership: content.fileOwnership
            )
        case .file(let url):
            let preparedURL: URL
            let preparedOwnership: ClipboardMonitor.ClipboardContent.FileOwnership
            if content.fileOwnership == .durableSpool {
                guard let copiedURL = await Task.detached(priority: .utility, operation: {
                    try? ClipboardMonitor.createTransientWorkCopy(for: content)
                }).value else {
                    return content
                }
                let replaced = await Task.detached(priority: .utility) {
                    PngquantService.compressFileBestEffort(copiedURL, options: options)
                }.value
                guard replaced else {
                    try? FileManager.default.removeItem(at: copiedURL)
                    return content
                }
                preparedURL = copiedURL
                preparedOwnership = .transient
            } else {
                let replaced = await Task.detached(priority: .utility) {
                    PngquantService.compressFileBestEffort(url, options: options)
                }.value
                guard replaced else { return content }
                preparedURL = url
                preparedOwnership = content.fileOwnership
            }

            let updatedSize: Int = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: preparedURL.path),
                      let size = attrs[.size] as? Int else { return content.sizeBytes }
                return size
            }()

            let updatedHash: String = {
                guard let data = try? Data(contentsOf: preparedURL, options: [.mappedIfSafe]) else {
                    return content.contentHash
                }
                return ClipboardMonitor.computeHashStatic(data)
            }()

            return ClipboardMonitor.ClipboardContent(
                type: content.type,
                plainText: content.plainText,
                payload: .file(preparedURL),
                note: content.note,
                appBundleID: content.appBundleID,
                contentHash: updatedHash,
                sizeBytes: updatedSize,
                fileSizeBytes: content.fileSizeBytes,
                ingestEnvelopeURL: content.ingestEnvelopeURL,
                ingestID: content.ingestID,
                fileOwnership: preparedOwnership
            )
        case .none:
            return content
        }
    }

    private func acknowledgeIngestEnvelopeIfNeeded(
        _ content: ClipboardMonitor.ClipboardContent,
        storage: StorageService
    ) async {
        guard let envelopeURL = content.ingestEnvelopeURL else { return }
        let outcome = await MainActor.run { [monitor] in
            monitor?.acknowledgeIngestEnvelope(at: envelopeURL)
        }
        guard case .terminal(let acknowledgement) = outcome else { return }
        do {
            try await storage.removeIngestReceipt(acknowledgement.ingestID)
            _ = await MainActor.run { [monitor] in
                monitor?.completeTerminalIngestAcknowledgement(acknowledgement)
            }
        } catch {
            ScopyLog.app.warning(
                "Failed to complete ingest acknowledgement: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func yieldEvent(_ event: ClipboardEvent) async {
        await eventQueue.enqueue(event)
    }

    private func cleanupCommitHandler() -> StorageService.CleanupCommitHandler {
        { [weak self] result in
            guard let self else { return }
            await self.handoffCommittedCleanup(result)
        }
    }

    /// The caller may be a debounce task that becomes cancelled after SQLite commits. A detached
    /// handoff gives the already-committed search/UI convergence work an independent cancellation
    /// lifetime; cancellation remains meaningful only before a cleanup commit.
    private func handoffCommittedCleanup(_ result: StorageService.CleanupResult) async {
        guard !result.deletedItemIDs.isEmpty else { return }
        let handoff = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.publishCommittedCleanup(result)
        }
        await handoff.value
    }

    private func publishCommittedCleanup(_ result: StorageService.CleanupResult) async {
        var seen: Set<UUID> = []
        let deletedItemIDs = result.deletedItemIDs.filter { seen.insert($0).inserted }
        guard !deletedItemIDs.isEmpty else { return }
        let deletedSet = Set(deletedItemIDs)

        await search?.applyCommittedChanges()
        fileSizeComputationLastAttemptAt.remove { deletedSet.contains($0.itemID) }
        await fileSizeComputationQueue?.cancelPending { deletedSet.contains($0.itemID) }
        await eventQueue.invalidatePublications(itemIDs: deletedItemIDs)
        await yieldEvent(.itemsRemoved(deletedItemIDs))
    }

    private func reservePublication(for itemID: UUID) async -> ClipboardEventQueue.PublicationToken {
        await eventQueue.reservePublication(itemID: itemID)
    }

    @discardableResult
    private func yieldEvent(
        _ event: ClipboardEvent,
        publication: ClipboardEventQueue.PublicationToken
    ) async -> Bool {
        await eventQueue.enqueue(event, publication: publication)
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
            _ = try await storage.performCleanup(
                mode: mode,
                policy: cleanupPolicy(),
                onCommitted: cleanupCommitHandler()
            )
            lastLightCleanupAt = now
            if needsFull { lastFullCleanupAt = now }
        } catch {
            ScopyLog.app.warning("Scheduled cleanup failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func startBackgroundMediaQueuesIfNeeded() async {
        await startThumbnailGenerationQueueIfNeeded()
        await startFileSizeComputationQueueIfNeeded()
    }

    private func startThumbnailGenerationQueueIfNeeded() async {
        guard isStarted, thumbnailGenerationQueue == nil else { return }

        let queue = ThumbnailWorkQueue(
            workerLimit: maxConcurrentThumbnailGenerations,
            pendingLimit: maxPendingThumbnailGenerations,
            merge: { existing, incoming in
                var itemIDs = existing.itemIDs
                itemIDs.formUnion(incoming.itemIDs)
                return ThumbnailGenerationWork(
                    item: incoming.item,
                    itemIDs: itemIDs,
                    maxHeight: incoming.maxHeight,
                    externalStorageRoot: incoming.externalStorageRoot,
                    thumbnailCacheRoot: incoming.thumbnailCacheRoot
                )
            },
            operation: { [weak self] work, priority in
                guard let self else { return nil }
                return await self.performThumbnailGeneration(work, priority: priority)
            },
            completion: { [weak self] work, thumbnailPath in
                guard let self, let thumbnailPath else { return }
                await self.publishGeneratedThumbnail(work, thumbnailPath: thumbnailPath)
            }
        )
        thumbnailGenerationQueue = queue
        await queue.start()
    }

    private func startFileSizeComputationQueueIfNeeded() async {
        guard isStarted, fileSizeComputationQueue == nil else { return }

        let queue = FileSizeWorkQueue(
            workerLimit: maxConcurrentFileSizeComputations,
            pendingLimit: maxPendingFileSizeComputations,
            merge: { _, incoming in incoming },
            operation: { [weak self] work, _ in
                guard let self else { return nil }
                return await self.performFileSizeComputation(work)
            },
            completion: { [weak self] _, result in
                guard let self, let result else { return }
                await self.applyComputedFileSizeBytes(
                    expected: result.expected,
                    fileSizeBytes: result.fileSizeBytes
                )
            }
        )
        fileSizeComputationQueue = queue
        await queue.start()
    }

    private func stopThumbnailGenerationQueue() async {
        let queue = thumbnailGenerationQueue
        thumbnailGenerationQueue = nil
        await queue?.stop()
    }

    private func stopBackgroundMediaQueues() async {
        let thumbnailQueue = thumbnailGenerationQueue
        let fileSizeQueue = fileSizeComputationQueue
        thumbnailGenerationQueue = nil
        fileSizeComputationQueue = nil
        await thumbnailQueue?.stop()
        await fileSizeQueue?.stop()
        fileSizeComputationLastAttemptAt.removeAll()
    }

    private func toDTO(
        _ item: ClipboardStoredItem,
        storage: StorageService,
        thumbnailGenerationPriority: TaskPriority = .utility
    ) async -> ClipboardItemDTO {
        var thumbnailPath: String? = nil
        let fileSizeBytes: Int? = item.fileSizeBytes
        if settings.showImageThumbnails {
            let thumbnailCacheRoot = storage.thumbnailCacheDirectoryPath
            switch item.type {
            case .image:
                let filename = "\(item.contentHash).png"
                if let path = thumbnailPathIfExists(filename: filename, thumbnailCacheRoot: thumbnailCacheRoot) {
                    thumbnailPath = path
                } else if shouldScheduleImageThumbnailGeneration(for: item, externalStorageRoot: storage.externalStorageDirectoryPath) {
                    await scheduleThumbnailGenerationIfNeeded(
                        for: item,
                        storage: storage,
                        priority: thumbnailGenerationPriority
                    )
                }
            case .file:
                if let preview = FilePreviewSupport.previewSummary(from: item.plainText, requireExists: false),
                   preview.shouldGenerateThumbnail {
                    let filename = StorageService.fileThumbnailFilename(for: item.contentHash)
                    if let path = thumbnailPathIfExists(filename: filename, thumbnailCacheRoot: thumbnailCacheRoot) {
                        thumbnailPath = path
                    } else {
                        await scheduleThumbnailGenerationIfNeeded(
                            for: item,
                            storage: storage,
                            priority: thumbnailGenerationPriority
                        )
                    }
                }
            default:
                break
            }
        }

        if item.type == .file, fileSizeBytes == nil {
            await scheduleFileSizeComputationIfNeeded(expected: item)
        }

        return ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            note: item.note,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: fileSizeBytes,
            thumbnailPath: thumbnailPath,
            storageRef: item.storageRef
        )
    }

    private func scheduleThumbnailGenerationIfNeeded(
        for item: ClipboardStoredItem,
        storage: StorageService,
        priority: TaskPriority
    ) async {
        guard let queue = thumbnailGenerationQueue else { return }
        let typeNamespace = item.type == .file ? "file" : "image"
        let key = ThumbnailGenerationKey(typeNamespace: typeNamespace, contentHash: item.contentHash)
        let work = ThumbnailGenerationWork(
            item: item,
            itemIDs: [item.id],
            maxHeight: settings.thumbnailHeight,
            externalStorageRoot: storage.externalStorageDirectoryPath,
            thumbnailCacheRoot: storage.thumbnailCacheDirectoryPath
        )
        _ = await queue.submit(
            key: key,
            work: work,
            priority: Self.backgroundWorkPriority(from: priority)
        )
    }

    private func scheduleFileSizeComputationIfNeeded(expected: ClipboardStoredItem) async {
        let key = FileSizeComputationKey(expected: expected)
        let now = Date()
        if fileSizeComputationLastAttemptAt.containsRecent(
            key,
            now: now,
            interval: fileSizeComputationRetryInterval
        ) {
            return
        }
        guard let queue = fileSizeComputationQueue else { return }
        _ = await queue.cancelPending { pendingKey in
            pendingKey.itemID == expected.id && pendingKey != key
        }
        _ = await queue.submit(
            key: key,
            work: FileSizeComputationWork(expected: expected),
            priority: .utility
        )
    }

    private func performFileSizeComputation(_ work: FileSizeComputationWork) async -> FileSizeComputationResult? {
        guard isStarted, !Task.isCancelled else { return nil }
        let key = FileSizeComputationKey(expected: work.expected)
        fileSizeComputationLastAttemptAt.record(key, at: Date())

        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let fileSizeBytes = FilePreviewSupport.totalFileSizeBytes(from: work.expected.plainText) else {
                return nil as FileSizeComputationResult?
            }
            return FileSizeComputationResult(expected: work.expected, fileSizeBytes: fileSizeBytes)
        }
        return await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    func applyComputedFileSizeBytes(
        expected: ClipboardStoredItem,
        fileSizeBytes: Int
    ) async {
        guard isStarted, let storage else { return }
        let key = FileSizeComputationKey(expected: expected)

        do {
            guard try await storage.updateFileSizeBytes(
                expected: expected,
                fileSizeBytes: fileSizeBytes
            ) != nil else {
                fileSizeComputationLastAttemptAt.remove(key)
                return
            }
            fileSizeComputationLastAttemptAt.remove(key)
            await metadataPublicationInterlock?(.afterFileSizeCommit, expected.id)
            _ = await publishAuthoritativeItemState(
                id: expected.id,
                storage: storage,
                priority: .utility,
                metadataInterlockPoint: .afterFileSizeDTOConstructionBeforeEvent
            )
        } catch {
            ScopyLog.app.warning("Failed to update fileSizeBytes for item \(expected.id.uuidString, privacy: .private): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func performThumbnailGeneration(
        _ work: ThumbnailGenerationWork,
        priority: BackgroundWorkPriority
    ) async -> String? {
        guard isStarted, !Task.isCancelled, let storage else { return nil }
        let item = work.item
        let quickLookScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let storagePath = item.storageRef
        let rawData = item.rawData
        let fallbackImageData: Data?
        if item.type == .image,
           (storagePath == nil || storagePath?.isEmpty == true),
           rawData == nil,
           !Task.isCancelled {
            fallbackImageData = await storage.loadPayloadData(for: item)
        } else {
            fallbackImageData = nil
        }
        guard !Task.isCancelled else { return nil }

        let generationTask = Task.detached(priority: priority.taskPriority) {
            await Self.generateAndPersistThumbnail(
                work: work,
                quickLookScale: quickLookScale,
                fallbackImageData: fallbackImageData
            )
        }
        return await withTaskCancellationHandler(operation: {
            await generationTask.value
        }, onCancel: {
            generationTask.cancel()
        })
    }

    nonisolated private static func generateAndPersistThumbnail(
        work: ThumbnailGenerationWork,
        quickLookScale: CGFloat,
        fallbackImageData: Data?
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        let item = work.item
        let pngData: Data?
        switch item.type {
            case .image:
                if let storagePath = item.storageRef, !storagePath.isEmpty {
                    guard StorageService.validateStorageRef(
                        storagePath,
                        externalStoragePath: work.externalStorageRoot
                    ) else {
                        ScopyLog.app.warning("Thumbnail skipped: invalid storageRef (possible traversal)")
                        return nil
                    }
                    pngData = StorageService.makeThumbnailPNG(
                        fromFileAtPath: storagePath,
                        maxHeight: work.maxHeight
                    )
                } else if let rawData = item.rawData {
                    pngData = StorageService.makeThumbnailPNG(from: rawData, maxHeight: work.maxHeight)
                } else if let fallbackImageData {
                    pngData = StorageService.makeThumbnailPNG(
                        from: fallbackImageData,
                        maxHeight: work.maxHeight
                    )
                } else {
                    pngData = nil
                }
            case .file:
                guard let preview = FilePreviewSupport.previewSummary(from: item.plainText, requireExists: true),
                      preview.shouldGenerateThumbnail else {
                    return nil
                }
                switch preview.kind {
                case .image:
                    pngData = StorageService.makeThumbnailPNG(
                        fromFileAtPath: preview.path,
                        maxHeight: work.maxHeight
                    )
                case .video:
                    pngData = FilePreviewSupport.makeVideoThumbnailPNG(
                        from: preview.info.url,
                        maxHeight: work.maxHeight
                    )
                case .other:
                    let maxSidePixels = max(1, Int(CGFloat(work.maxHeight) * quickLookScale))
                    pngData = await FilePreviewSupport.makeQuickLookThumbnailPNG(
                        from: preview.info.url,
                        maxSidePixels: maxSidePixels,
                        scale: quickLookScale
                    )
                }
            default:
                pngData = nil
        }

        guard !Task.isCancelled, let pngData else { return nil }
        let filename = item.type == .file
            ? StorageService.fileThumbnailFilename(for: item.contentHash)
            : "\(item.contentHash).png"
        let thumbnailPath = (work.thumbnailCacheRoot as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: thumbnailPath) {
            return thumbnailPath
        }
        if !FileManager.default.fileExists(atPath: work.thumbnailCacheRoot) {
            try? FileManager.default.createDirectory(
                atPath: work.thumbnailCacheRoot,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        guard !Task.isCancelled else { return nil }
        do {
            try StorageService.writeAtomically(pngData, to: thumbnailPath)
            return Task.isCancelled ? nil : thumbnailPath
        } catch {
            ScopyLog.app.warning("Failed to write thumbnail: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    private func publishGeneratedThumbnail(
        _ work: ThumbnailGenerationWork,
        thumbnailPath: String
    ) async {
        guard isStarted, settings.showImageThumbnails, let storage else { return }
        rememberThumbnailExists(thumbnailPath: thumbnailPath)
        let itemIDs = work.itemIDs.sorted { $0.uuidString < $1.uuidString }
        for itemID in itemIDs {
            let publication = await reservePublication(for: itemID)
            guard let current = try? await storage.findByID(itemID),
                  current.type == work.item.type,
                  current.contentHash == work.item.contentHash else {
                await eventQueue.discardPublication(publication)
                continue
            }
            await yieldEvent(
                .thumbnailUpdated(
                    itemID: itemID,
                    expectedType: work.item.type,
                    expectedContentHash: work.item.contentHash,
                    thumbnailPath: thumbnailPath
                ),
                publication: publication
            )
        }
    }

    nonisolated private static func backgroundWorkPriority(
        from taskPriority: TaskPriority
    ) -> BackgroundWorkPriority {
        taskPriority == .userInitiated || taskPriority == .high ? .userInitiated : .utility
    }

}

// MARK: - Thumbnail Cache Index

extension ClipboardBackend {
    private func scheduleThumbnailCacheIndexBuildIfNeeded(thumbnailCacheRoot: String) {
        guard !thumbnailCacheRoot.isEmpty else { return }

        if let index = thumbnailCacheIndex, index.root == thumbnailCacheRoot {
            return
        }

        thumbnailCacheIndexTask?.cancel()
        let generation = thumbnailCacheIndexGeneration
        thumbnailCacheIndexTask = Task.detached(priority: .utility) { [weak self, thumbnailCacheRoot, generation] in
            let filenames: [String]
            do {
                filenames = try FileManager.default.contentsOfDirectory(atPath: thumbnailCacheRoot)
            } catch {
                filenames = []
            }

            guard !Task.isCancelled else { return }

            let index = ThumbnailCacheIndex(root: thumbnailCacheRoot, filenames: Set(filenames))
            await self?.setThumbnailCacheIndex(index, generation: generation)
        }
    }

    private func setThumbnailCacheIndex(_ index: ThumbnailCacheIndex, generation: UInt64) {
        guard generation == thumbnailCacheIndexGeneration else { return }
        thumbnailCacheIndex = index
    }

    private func invalidateThumbnailCacheIndex() {
        thumbnailCacheIndexGeneration &+= 1
        thumbnailCacheIndexTask?.cancel()
        thumbnailCacheIndexTask = nil
        thumbnailCacheIndex = nil
    }

    private func thumbnailPathIfExists(filename: String, thumbnailCacheRoot: String) -> String? {
        if var index = thumbnailCacheIndex, index.root == thumbnailCacheRoot {
            let path = index.pathIfExists(filename: filename)
            thumbnailCacheIndex = index
            return path
        }

        let path = (thumbnailCacheRoot as NSString).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if var index = thumbnailCacheIndex, index.root == thumbnailCacheRoot {
            index.remember(filename: filename)
            thumbnailCacheIndex = index
        } else {
            thumbnailCacheIndex = ThumbnailCacheIndex(root: thumbnailCacheRoot, filenames: [filename])
        }

        return path
    }

    private func rememberThumbnailExists(thumbnailPath: String) {
        let root = (thumbnailPath as NSString).deletingLastPathComponent
        guard !root.isEmpty else { return }

        let filename = (thumbnailPath as NSString).lastPathComponent
        guard !filename.isEmpty else { return }

        if var index = thumbnailCacheIndex, index.root == root {
            index.remember(filename: filename)
            thumbnailCacheIndex = index
        } else {
            thumbnailCacheIndex = ThumbnailCacheIndex(root: root, filenames: [filename])
        }
    }

    private func shouldScheduleImageThumbnailGeneration(for item: ClipboardStoredItem, externalStorageRoot: String) -> Bool {
        guard item.type == .image else { return false }

        guard let storageRef = item.storageRef, !storageRef.isEmpty else {
            return true
        }

        let filename = (storageRef as NSString).lastPathComponent
        let nameWithoutExt = (filename as NSString).deletingPathExtension

        // Mirror the early safe checks of `StorageService.validateStorageRef` without touching filesystem.
        guard UUID(uuidString: nameWithoutExt) != nil else { return false }
        guard !storageRef.contains("..") && !filename.contains("/") else { return false }

        let allowedPath = (externalStorageRoot as NSString).standardizingPath
        let normalizedRef = (storageRef as NSString).standardizingPath
        guard normalizedRef.hasPrefix(allowedPath + "/") else { return false }

        return true
    }
}
