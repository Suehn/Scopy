import AppKit
import Foundation

/// The backend facade: composes monitor, storage, search, and settings, and owns the event stream.
/// `ClipboardMonitor` is `@MainActor`; `StorageService` is its own actor,
/// so storage calls never touch the main thread. The UI reaches this actor through `RealClipboardService`.
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
        case beforeResultValidation
    }

    private enum ExternalSourceReconciliationResult: Sendable {
        case adopted
        case sourceUnavailable
        case failedOrUnstable
    }

    private struct HistoryPublicationWaiter {
        let mutationSeq: Int64
        let continuation: CheckedContinuation<Void, Never>
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

    private let eventQueue: AsyncBoundedQueue<ClipboardEvent>
    private var historyPublicationTask: Task<Void, Never>?
    /// Highest log position represented by an enqueued fact or resnapshot signal. The UI's
    /// applied snapshot position is separate and comes from its actual database read.
    private var publishedMutationSeq: Int64 = 0
    private var historyPublicationWaiters: [HistoryPublicationWaiter] = []
    #if DEBUG
    private var beforeHistoryPublicationForTesting: (@Sendable (Int64) async -> Void)?
    var isDrainingHistoryForTesting: Bool { !historyPublicationWaiters.isEmpty }

    func setHistoryPublicationInterlockForTesting(_ interlock: (@Sendable (Int64) async -> Void)?) {
        beforeHistoryPublicationForTesting = interlock
    }
    #endif
    private var monitorTask: Task<Void, Never>?
    private var storageRootLock: StorageRootLock?
    private var memoryPressureSources: [any DispatchSourceMemoryPressure] = []
    private enum Lifecycle {
        case stopped
        case starting(Task<Void, Error>)
        case running
        case stopping(Task<Void, Never>)
    }

    private var lifecycle: Lifecycle = .stopped
    private var isStarted: Bool {
        if case .running = lifecycle { return true }
        return false
    }
    private var activeStorageRequests = 0
    private var storageRequestsDrained: CheckedContinuation<Void, Never>?
    #if DEBUG
    var isDrainingStorageRequestsForTesting: Bool { storageRequestsDrained != nil }
    #endif
    private var orphanCleanupTask: Task<Void, Never>?
    private var captureStatusMonitorID: UUID?
    private var captureStatusRevision: UInt64 = 0
    private var captureStatusTask: Task<Void, Never>?

    // MARK: - Cleanup Scheduling

    private var cleanupTask: Task<Void, Never>?
    private var cleanupDeadline: ContinuousClock.Instant?
    private var lastLightCleanupAt: Date = .distantPast
    private var lastFullCleanupAt: Date = .distantPast
    private let lightCleanupInterval: TimeInterval = 60
    private let fullCleanupInterval: TimeInterval = 3600
    private let cleanupDebounceDelay: Duration = .seconds(2)

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
        imageOptimizationInterlock: (@Sendable (ImageOptimizationInterlockPoint, UUID) async -> Void)? = nil
    ) {
        self.databasePath = databasePath
        self.settingsStore = settingsStore
        self.monitorPasteboardName = monitorPasteboardName
        self.monitorPollingInterval = monitorPollingInterval
        self.imageOptimizationInterlock = imageOptimizationInterlock

        let queue = AsyncBoundedQueue<ClipboardEvent>(capacity: ScopyThresholds.clipboardEventStreamMaxBufferedItems)
        self.eventQueue = queue
        self.eventStream = AsyncStream(unfolding: { await queue.dequeue() })
    }

    deinit {
        historyPublicationTask?.cancel()
        monitorTask?.cancel()
        cleanupTask?.cancel()
        orphanCleanupTask?.cancel()
        captureStatusTask?.cancel()
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
        switch lifecycle {
        case .running:
            return
        case .starting(let task):
            try await task.value
        case .stopping(let task):
            await task.value
            try await start()
        case .stopped:
            let task = Task {
                do {
                    try await startResources()
                    lifecycle = .running
                } catch {
                    lifecycle = .stopped
                    throw error
                }
            }
            lifecycle = .starting(task)
            try await task.value
        }
    }

    private func startResources() async throws {
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

        let captureStatusMonitorID = UUID()
        self.captureStatusMonitorID = captureStatusMonitorID
        self.captureStatusRevision = 0
        let monitor = await MainActor.run {
            let pasteboard: NSPasteboard
            if let pasteboardName, !pasteboardName.isEmpty {
                pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
            } else {
                pasteboard = .general
            }
            let monitor = ClipboardMonitor(
                pasteboard: pasteboard,
                pollingInterval: pollingInterval,
                ingestSpoolDirectory: ingestSpoolDirectory,
                legacyIngestSpoolDirectory: legacyIngestSpoolDirectory,
                spoolAlreadyPrepared: true
            )
            monitor.onCaptureReadBlockedChanged = { [weak self] blocked, revision in
                Task { [weak self] in
                    await self?.publishCaptureReadStatus(blocked, revision: revision, monitorID: captureStatusMonitorID)
                }
            }
            return monitor
        }

        let search = SearchEngineImpl(dbPath: storage.databaseFilePath, commitJournal: storage.commitJournal)

        do {
            try await storage.open()
            try await search.open()
            startHistoryPublication(storage: storage)

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

            self.settings = loadedSettings
            self.monitor = monitor
            self.storage = storage
            self.search = search
            self.storageRootLock = rootLock
            startMemoryPressureMonitoring()

            await startBackgroundMediaQueuesIfNeeded()
            scheduleThumbnailCacheIndexBuildIfNeeded(thumbnailCacheRoot: storage.thumbnailCacheDirectoryPath)
            orphanCleanupTask = Task { [storage] in
                try? await storage.cleanupOrphanedFiles()
            }

            await monitor.startMonitoring()
            let stream = monitor.contentStream
            monitorTask = Task { [weak self] in
                for await content in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    guard let self else { return }
                    await self.handleNewContent(content)
                }
            }
        } catch {
            self.captureStatusMonitorID = nil
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
        guard let storage = try? beginStorageRequest() else { return }
        defer { endStorageRequest() }
        await search?.trimSessionMemory(critical ? .memoryCritical : .memoryWarning)
        if critical {
            await storage.repository.releaseMemory()
        }
    }

    func stop() async {
        switch lifecycle {
        case .stopped:
            return
        case .starting(let task):
            _ = try? await task.value
            await stop()
        case .stopping(let task):
            await task.value
        case .running:
            let task = Task {
                await stopResources()
                lifecycle = .stopped
            }
            lifecycle = .stopping(task)
            await task.value
        }
    }

    private func stopResources() async {
        captureStatusMonitorID = nil
        memoryPressureSources.forEach { $0.cancel() }
        memoryPressureSources = []

        // Keep every resource and task owner until its work has returned. A cancelled task may
        // still own a spool write, a committed cleanup publication, or a managed-file unlink.
        monitorTask?.cancel()
        cleanupTask?.cancel()
        orphanCleanupTask?.cancel()
        thumbnailCacheIndexTask?.cancel()
        captureStatusTask?.cancel()
        await monitor?.stopAndWait()
        await stopBackgroundMediaQueues()
        await monitorTask?.value
        await cleanupTask?.value
        await orphanCleanupTask?.value
        await thumbnailCacheIndexTask?.value
        await captureStatusTask?.value

        if activeStorageRequests > 0 {
            await withCheckedContinuation { storageRequestsDrained = $0 }
        }

        // No producer can commit now. Publish the remaining facts before cancelling the sole
        // history consumer; its cancellation lifetime is independent of every initiating request.
        if let storage {
            await waitForHistoryPublication(through: storage.commitJournal.currentMutationSeq)
        }
        historyPublicationTask?.cancel()
        await historyPublicationTask?.value
        historyPublicationTask = nil

        // Only the writer, closing after the read connection, can checkpoint and truncate WAL.
        await search?.close()
        await storage?.close()

        monitorTask = nil
        cleanupTask = nil
        orphanCleanupTask = nil
        thumbnailCacheIndexTask = nil
        captureStatusTask = nil
        thumbnailCacheIndex = nil
        self.monitor = nil
        self.storage = nil
        self.search = nil
        storageRootLock?.release()
        storageRootLock = nil
    }

    // MARK: - Data Access

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let items = try await storage.fetchRecent(limit: limit, offset: offset)
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let items = try await storage.fetchPinned()
        var dtos: [ClipboardItemDTO] = []
        dtos.reserveCapacity(items.count)
        for item in items {
            dtos.append(await toDTO(item, storage: storage))
        }
        return dtos
    }

    func fetchHistoryPage(limit: Int, after cursor: RecentHistoryCursor?) async throws -> RecentHistoryPage {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let page = try await storage.fetchHistoryPage(limit: limit, after: cursor)
        var pinned: [ClipboardItemDTO] = []
        var items: [ClipboardItemDTO] = []
        for item in page.pinned { pinned.append(await toDTO(item, storage: storage)) }
        for item in page.items { items.append(await toDTO(item, storage: storage)) }
        return RecentHistoryPage(
            pinnedItems: pinned, items: items, total: page.total,
            nextCursor: page.nextCursor, mutationSeq: page.mutationSeq
        )
    }

    func fetchHistoryItems(itemIDs: Set<UUID>) async throws -> HistoryItemsSnapshot {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let snapshot = try await storage.fetchHistoryItems(itemIDs: itemIDs)
        var items: [ClipboardItemDTO] = []
        items.reserveCapacity(snapshot.items.count)
        for item in snapshot.items {
            items.append(await toDTO(item, storage: storage))
        }
        return HistoryItemsSnapshot(
            requestedItemIDs: itemIDs, items: items, mutationSeq: snapshot.mutationSeq
        )
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
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
            coverage: result.coverage,
            mutationSeq: result.mutationSeq
        )
    }

    func pin(itemID: UUID) async throws {
        try await setPinned(itemID: itemID, pinned: true)
    }

    func unpin(itemID: UUID) async throws {
        try await setPinned(itemID: itemID, pinned: false)
    }

    private func setPinned(itemID: UUID, pinned: Bool) async throws {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        try Task.checkCancellation()
        try await storage.setPin(itemID, pinned: pinned)
    }

    func updateNote(itemID: UUID, note: String?) async throws {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard try await storage.updateNote(id: itemID, note: normalized) != nil else {
            throw ClipboardBackendError.itemNotFoundOrSuperseded
        }
    }

    func delete(itemID: UUID, expectedUseCount: Int) async throws -> HistoryItemsSnapshot {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let outcome = try await storage.deleteItem(itemID, expectedUseCount: expectedUseCount)
        let items: [ClipboardItemDTO]
        if let retained = outcome.item {
            items = [await toDTO(retained, storage: storage)]
        } else {
            items = []
        }
        return HistoryItemsSnapshot(
            requestedItemIDs: [itemID], items: items, mutationSeq: outcome.mutationSeq
        )
    }

    func clearAll() async throws {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        try await storage.deleteAllExceptPinned()
        await waitForHistoryPublication(through: storage.commitJournal.currentMutationSeq)
    }

    func copyToClipboard(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID, imageWriteMode: .standard)
    }

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID, imageWriteMode: .codexOptimized)
    }

    func fileURLs(itemID: UUID) async throws -> [URL] {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
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
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }

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

    func updateSettings(_ requestedPatch: SettingsPatch) async throws -> SettingsDTO {
        // Settings can be saved before startup. Only a running session applies storage side effects.
        let sessionStorage = isStarted ? try beginStorageRequest() : nil
        let sessionMonitor = sessionStorage == nil ? nil : monitor
        defer { if sessionStorage != nil { endStorageRequest() } }
        let oldSettings = settings
        let oldPollingMs = settings.clipboardPollingIntervalMs

        let newSettings = await settingsStore.apply(requestedPatch)
        let patch = SettingsPatch.from(baseline: oldSettings, draft: newSettings)
        settings = newSettings

        if monitorPollingInterval == nil,
           oldPollingMs != newSettings.clipboardPollingIntervalMs,
           let monitor = sessionMonitor {
            await MainActor.run {
                monitor.setPollingInterval(TimeInterval(newSettings.clipboardPollingIntervalMs) / 1000.0)
            }
        }

        if let storage = sessionStorage {
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
                        policy: cleanupPolicy()
                    )
                } catch {
                    ScopyLog.app.warning(
                        "Cleanup failed after settings update: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        await yieldEvent(.settingsChanged)
        return newSettings
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
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let count = try await storage.getItemCount()
        let contentSize = try await storage.getTotalSize()
        return (count, contentSize)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
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
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        let updated = try await storage.syncExternalImageSizeBytesFromDisk()
        if updated > 0 {
            ScopyLog.storage.info("Synced external image size_bytes from disk: updated=\(updated, privacy: .public)")
        }
        return updated
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        guard let item = try await storage.findByID(itemID) else { return nil }
        return await storage.loadPayloadData(for: item)
    }

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
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
                try await PngquantService.compressPNGData(rawData, options: options)
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
            guard await optimizedPayloadStillCurrent(updated, storage: storage) else {
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
                try await PngquantService.compressPNGFileInPlace(stagedURL, options: options)
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
                break
            case .adopted, .failedOrUnstable:
                return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
            }
        }

        guard await optimizedPayloadStillCurrent(updated, storage: storage) else {
            return Self.supersededImageOptimizationOutcome(originalBytes: originalBytes)
        }
        return ImageOptimizationOutcomeDTO(
            result: .optimized,
            originalBytes: originalBytes,
            optimizedBytes: optimizedBytes,
            resultingContentHash: newHash
        )
    }

    /// The result's proof concerns payload ownership at completion, not history publication.
    /// History always publishes the immutable transaction value, even if another commit follows it.
    private func optimizedPayloadStillCurrent(
        _ updated: ClipboardStoredItem,
        storage: StorageService
    ) async -> Bool {
        await imageOptimizationInterlock?(.beforeResultValidation, updated.id)
        guard let current = try? await storage.findByID(updated.id) else { return false }
        return Self.hasSamePayload(current, as: updated)
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
        let storage = try beginStorageRequest()
        defer { endStorageRequest() }
        return try await storage.getRecentApps(limit: limit)
    }

    // MARK: - Internals

    private func publishCaptureReadStatus(_ blocked: Bool, revision: UInt64, monitorID: UUID) {
        // Callback tasks can arrive after stop/restart or out of order. The latest status owns
        // its send task, so queue backpressure cannot keep an obsolete sender alive on shutdown.
        guard captureStatusMonitorID == monitorID, revision > captureStatusRevision else { return }
        captureStatusRevision = revision
        captureStatusTask?.cancel()
        captureStatusTask = Task { [eventQueue] in
            await eventQueue.enqueue(.captureReadBlocked(blocked))
        }
    }

    private func requireMonitor() throws -> ClipboardMonitor {
        guard let monitor else { throw ClipboardBackendError.notStarted }
        return monitor
    }

    /// Public requests borrow the running store across suspension. Shutdown stops admission and
    /// waits for the last borrower before closing SQLite or releasing the storage-root lock.
    private func beginStorageRequest() throws -> StorageService {
        guard isStarted, let storage else { throw ClipboardBackendError.notStarted }
        activeStorageRequests += 1
        return storage
    }

    private func endStorageRequest() {
        activeStorageRequests -= 1
        if activeStorageRequests == 0 {
            storageRequestsDrained?.resume()
            storageRequestsDrained = nil
        }
    }

    private func requireSearch() throws -> SearchEngineImpl {
        guard let search else { throw ClipboardBackendError.notStarted }
        return search
    }

    private func handleNewContent(_ content: ClipboardMonitor.ClipboardContent) async {
        guard let storage, search != nil else { return }

        if content.type == .image && !settings.saveImages {
            await acknowledgeIngestEnvelopeIfNeeded(content, storage: storage)
            return
        }
        if content.type == .file && !settings.saveFiles {
            await acknowledgeIngestEnvelopeIfNeeded(content, storage: storage)
            return
        }

        let preparedContent = await prepareContentForStorage(content)

        do {
            _ = try await storage.upsertItemWithOutcome(preparedContent)
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

        let payload: CapturedPayload
        let contentHash: String
        let sizeBytes: Int
        switch content.payload.storage {
        case .data(let data):
            let compressed = await PngquantService.compressBestEffort(data, options: options)
            guard compressed != data else { return content }
            payload = content.payload.replacingData(compressed, type: content.type)
            contentHash = ClipboardMonitor.computeHashStatic(compressed)
            sizeBytes = compressed.count
        case .file:
            do {
                guard let transformed = try await content.payload.transformingFile({ input, output in
                    try await PngquantService.compressPNGFile(input, to: output, options: options)
                }) else { return content }
                payload = transformed.payload
                sizeBytes = transformed.data.count
                contentHash = ClipboardMonitor.computeHashStatic(transformed.data)
            } catch {
                return content
            }
        case .none:
            return content
        }

        return ClipboardMonitor.ClipboardContent(
            type: content.type,
            plainText: content.plainText,
            payload: payload,
            note: content.note,
            appBundleID: content.appBundleID,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            fileSizeBytes: content.fileSizeBytes
        )
    }

    private func acknowledgeIngestEnvelopeIfNeeded(
        _ content: ClipboardMonitor.ClipboardContent,
        storage: StorageService
    ) async {
        guard let envelopeURL = content.payload.ingest?.envelopeURL else { return }
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

    private func startHistoryPublication(storage: StorageService) {
        let journal = storage.commitJournal
        publishedMutationSeq = journal.currentMutationSeq
        let wakeups = journal.wakeups()
        historyPublicationTask = Task { [weak self] in
            for await _ in wakeups {
                guard !Task.isCancelled, let self else { return }
                await self.publishCommittedHistory(storage: storage)
            }
        }
    }

    /// The single consumer owns its cursor and serializes DTO hydration with event delivery.
    /// A wakeup is only a hint; the bounded log is the authority, including explicit history gaps.
    private func publishCommittedHistory(storage: StorageService) async {
        switch storage.commitJournal.read(after: publishedMutationSeq) {
        case .changes(let entries, _):
            for entry in entries {
                #if DEBUG
                await beforeHistoryPublicationForTesting?(entry.mutationSeq)
                #endif
                let change: HistoryChange
                switch entry.change {
                case .upserted(let item, let kind):
                    let dto = await toDTO(item, storage: storage, thumbnailGenerationPriority: .userInitiated)
                    change = .itemsChanged([dto], kind: kind)
                case .storageSizesUpdated(let items):
                    var dtos: [ClipboardItemDTO] = []
                    dtos.reserveCapacity(items.count)
                    for item in items {
                        dtos.append(await toDTO(item, storage: storage))
                    }
                    change = .itemsChanged(dtos, kind: .metadata)
                case .deleted(let ids):
                    await discardBackgroundWork(for: ids)
                    change = .itemsRemoved(ids)
                case .clearedUnpinned(let ids):
                    await discardBackgroundWork(for: ids)
                    await thumbnailGenerationQueue?.discardPending()
                    change = .itemsCleared(deletedItemIDs: ids)
                }
                await yieldEvent(.history(CommittedHistoryChange(
                    mutationSeq: entry.mutationSeq, totalCount: entry.totalCount, change: change
                )))
                advanceHistoryPublication(to: entry.mutationSeq)
            }
        case .resnapshotRequired(let through):
            await yieldEvent(.historyResnapshotRequired(mutationSeq: through))
            advanceHistoryPublication(to: through)
        }
    }

    private func discardBackgroundWork(for deletedItemIDs: [UUID]) async {
        let ids = Set(deletedItemIDs)
        fileSizeComputationLastAttemptAt.remove { ids.contains($0.itemID) }
        await fileSizeComputationQueue?.cancelPending { ids.contains($0.itemID) }
    }

    private func waitForHistoryPublication(through mutationSeq: Int64) async {
        guard publishedMutationSeq < mutationSeq else { return }
        await withCheckedContinuation { continuation in
            historyPublicationWaiters.append(
                HistoryPublicationWaiter(mutationSeq: mutationSeq, continuation: continuation)
            )
        }
    }

    private func advanceHistoryPublication(to mutationSeq: Int64) {
        publishedMutationSeq = mutationSeq
        let completed = historyPublicationWaiters.filter { $0.mutationSeq <= mutationSeq }
        historyPublicationWaiters.removeAll { $0.mutationSeq <= mutationSeq }
        completed.forEach { $0.continuation.resume() }
    }

    private func scheduleCleanup(storage: StorageService) {
        guard isStarted else { return }
        cleanupDeadline = .now.advanced(by: cleanupDebounceDelay)
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            await self?.runScheduledCleanup(storage: storage)
        }
    }

    /// One task owns both debounce and cleanup. New captures move the deadline without cancelling
    /// an already-running cleanup or losing its task handle after a commit.
    private func runScheduledCleanup(storage: StorageService) async {
        defer {
            cleanupTask = nil
            cleanupDeadline = nil
        }
        while let deadline = cleanupDeadline, !Task.isCancelled {
            do {
                try await Task.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard cleanupDeadline == deadline else { continue }
            cleanupDeadline = nil
            await runCleanupIfNeeded(storage: storage)
        }
    }

    private func runCleanupIfNeeded(storage: StorageService) async {
        let now = Date()
        let needsFull = now.timeIntervalSince(lastFullCleanupAt) >= fullCleanupInterval
        let needsLight = now.timeIntervalSince(lastLightCleanupAt) >= lightCleanupInterval
        guard needsLight || needsFull else { return }

        let mode: StorageService.CleanupMode = needsFull ? .full : .light
        do {
            _ = try await storage.performCleanup(
                mode: mode,
                policy: cleanupPolicy()
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
        guard thumbnailGenerationQueue == nil else { return }
        switch lifecycle {
        case .starting, .running: break
        case .stopped, .stopping: return
        }

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
        guard fileSizeComputationQueue == nil else { return }
        switch lifecycle {
        case .starting, .running: break
        case .stopped, .stopping: return
        }

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
            storageRef: item.storageRef,
            useCount: item.useCount
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
            // A log row is an immutable summary. Never place a later payload under its old
            // content-hash cache key when hydration races a replacement or deletion.
            guard let current = try? await storage.findByID(item.id),
                  current.type == item.type,
                  current.contentHash == item.contentHash,
                  current.storageRef == item.storageRef else { return nil }
            fallbackImageData = current.rawData
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
        guard isStarted, settings.showImageThumbnails else { return }
        rememberThumbnailExists(thumbnailPath: thumbnailPath)
        for itemID in work.itemIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            await yieldEvent(.thumbnailUpdated(
                itemID: itemID,
                expectedType: work.item.type,
                expectedContentHash: work.item.contentHash,
                thumbnailPath: thumbnailPath
            ))
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
