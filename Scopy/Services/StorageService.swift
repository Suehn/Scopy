import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private actor ExternalFileReservationRegistry {
    struct Reservation: Sendable {
        let id: UUID
        let resourceKeys: [String]
    }

    private struct Waiter {
        let id: UUID
        let resourceKeys: [String]
        let continuation: CheckedContinuation<Reservation?, Never>
    }

    private var owners: [String: UUID] = [:]
    private var waiters: [Waiter] = []

    deinit {
        waiters.forEach { $0.continuation.resume(returning: nil) }
    }

    func acquire(resourceKeys: [String]) async -> Reservation? {
        let normalized = Array(Set(resourceKeys.filter { !$0.isEmpty })).sorted()
        guard !normalized.isEmpty, !Task.isCancelled else { return nil }
        let requestID = UUID()

        let reservation: Reservation? = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if canAcquire(normalized) {
                    let reservation = Reservation(id: requestID, resourceKeys: normalized)
                    markOwned(reservation)
                    continuation.resume(returning: reservation)
                } else {
                    waiters.append(
                        Waiter(id: requestID, resourceKeys: normalized, continuation: continuation)
                    )
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: requestID) }
        })

        guard let reservation else { return nil }
        guard !Task.isCancelled else {
            release(reservation)
            return nil
        }
        return reservation
    }

    func release(_ reservation: Reservation) {
        for resourceKey in reservation.resourceKeys where owners[resourceKey] == reservation.id {
            owners.removeValue(forKey: resourceKey)
        }
        grantWaitersInOrder()
    }

    private func canAcquire(_ resourceKeys: [String]) -> Bool {
        resourceKeys.allSatisfy { owners[$0] == nil }
    }

    private func markOwned(_ reservation: Reservation) {
        for resourceKey in reservation.resourceKeys {
            owners[resourceKey] = reservation.id
        }
    }

    private func grantWaitersInOrder() {
        while let waiter = waiters.first, canAcquire(waiter.resourceKeys) {
            waiters.removeFirst()
            let reservation = Reservation(id: waiter.id, resourceKeys: waiter.resourceKeys)
            markOwned(reservation)
            waiter.continuation.resume(returning: reservation)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
        grantWaitersInOrder()
    }
}

/// Process-wide because multiple `StorageService` instances can legitimately target the same
/// content root (tests, restart handoff, or overlapping service lifetimes). Resource keys include
/// the canonical full path, so unrelated roots do not block each other.
private let sharedExternalFileReservations = ExternalFileReservationRegistry()

/// StorageService - 数据持久化服务
/// 符合 v0.md 第2节：分级存储（小内容SQLite内联，大内容外部文件）
@MainActor
public final class StorageService {
    // MARK: - Types

    enum StorageError: Error, LocalizedError {
        case databaseNotOpen
        case queryFailed(String)
        case insertFailed(String)
        case updateFailed(String)
        case deleteFailed(String)
        case fileOperationFailed(String)
        case migrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotOpen: return "Database is not open"
            case .queryFailed(let msg): return "Query failed: \(msg)"
            case .insertFailed(let msg): return "Insert failed: \(msg)"
            case .updateFailed(let msg): return "Update failed: \(msg)"
            case .deleteFailed(let msg): return "Delete failed: \(msg)"
            case .fileOperationFailed(let msg): return "File operation failed: \(msg)"
            case .migrationFailed(let msg): return "Migration failed: \(msg)"
            }
        }
    }

    public typealias StoredItem = ClipboardStoredItem

    enum UpsertOutcome: Sendable {
        case inserted(StoredItem)
        case updated(StoredItem)
        case alreadyApplied(StoredItem?)

        var item: StoredItem? {
            switch self {
            case .inserted(let item): return item
            case .updated(let item): return item
            case .alreadyApplied(let item): return item
            }
        }
    }

    enum ExternalSizeSyncInterlockPoint: Sendable {
        case afterStatBeforeCommit
    }

    enum OrphanCleanupInterlockPoint: Sendable {
        case afterEnumerationBeforeOwnershipValidation
        case afterOwnershipValidationBeforeRemove(path: String)
        case afterFinalOwnershipValidationBeforeRemove(path: String)
    }

    enum CleanupInterlockPoint: Sendable {
        case afterPlanBeforeCommit(plannedItemIDs: [UUID])
        case afterCommitBeforeFileCleanup(deletedItemIDs: [UUID])
    }

    enum IngestCommitInterlockPoint: Sendable {
        case beforeReceiptResolution(candidatePath: String?)
    }

    enum ExternalSourceReconciliationResult: Sendable, Equatable {
        case adopted
        case sourceUnavailable
        case failedOrUnstable
    }

    private enum OptimizedPayloadRepairResult {
        case restored(StoredItem)
        case independentlySuperseded
        case failed
    }

    struct ExternalImageSourceLease: Sendable {
        fileprivate let id: UUID
        fileprivate let sourceReservationKey: String
    }

    // MARK: - Configuration

    /// Threshold for external storage (v0.md: 小内容 < X KB)
    static let externalStorageThreshold = ScopyThresholds.externalStorageBytes

    /// Baseline concurrency limit for bulk filesystem deletions.
    /// Large cleanup batches can temporarily raise this via `fileDeletionConcurrency(for:)`.
    nonisolated static let maxConcurrentFileDeletions = 8

    public typealias FileRemover = @Sendable (URL) throws -> Void

    public struct StorageFileOps: Sendable {
        public let removeFile: FileRemover

        public init(removeFile: @escaping FileRemover) {
            self.removeFile = removeFile
        }

        public static let live = StorageFileOps(removeFile: { url in
            try StorageService.fastRemoveFile(url)
        })
    }

    /// Default cleanup settings (v0.md 2.1)
    public struct CleanupSettings {
        public var maxItems: Int = 10_000
        public var maxDaysAge: Int? = nil // nil = unlimited
        public var maxSmallStorageMB: Int = 200
        public var maxLargeStorageMB: Int = 800
        public var cleanupImagesOnly: Bool = false

        public init() {}
    }

    public struct CleanupResult: Sendable, Equatable {
        public let plannedItemCount: Int
        public let deletedItemIDs: [UUID]
        public let skippedItemCount: Int
        public let fileDeletionCandidateCount: Int
        public let fileDeletionAttemptCount: Int
        public let fileCleanupFailureCount: Int

        public static let empty = CleanupResult(
            plannedItemCount: 0,
            deletedItemIDs: [],
            skippedItemCount: 0,
            fileDeletionCandidateCount: 0,
            fileDeletionAttemptCount: 0,
            fileCleanupFailureCount: 0
        )

        fileprivate func merging(_ other: CleanupResult) -> CleanupResult {
            var seen = Set(deletedItemIDs)
            let uniqueAdditionalIDs = other.deletedItemIDs.filter { seen.insert($0).inserted }
            return CleanupResult(
                plannedItemCount: plannedItemCount + other.plannedItemCount,
                deletedItemIDs: deletedItemIDs + uniqueAdditionalIDs,
                skippedItemCount: skippedItemCount + other.skippedItemCount,
                fileDeletionCandidateCount: fileDeletionCandidateCount + other.fileDeletionCandidateCount,
                fileDeletionAttemptCount: fileDeletionAttemptCount + other.fileDeletionAttemptCount,
                fileCleanupFailureCount: fileCleanupFailureCount + other.fileCleanupFailureCount
            )
        }
    }

    private struct FileDeletionSummary: Sendable {
        let candidateCount: Int
        let attemptedCount: Int
        let cleanupFailureCount: Int

        static let empty = FileDeletionSummary(
            candidateCount: 0,
            attemptedCount: 0,
            cleanupFailureCount: 0
        )
    }

    typealias CleanupCommitHandler = @Sendable (CleanupResult) async -> Void

    // MARK: - Properties

    private let dbPath: String
    private let rootDirectory: URL
    private let externalStoragePath: String
    private let thumbnailCachePath: String
    private let fileOps: StorageFileOps

    /// Exposed as immutable values so non-`@MainActor` contexts can safely validate/read paths without capturing `StorageService`.
    nonisolated let externalStorageDirectoryPath: String
    nonisolated let thumbnailCacheDirectoryPath: String
    nonisolated let ingestSpoolDirectoryPath: String

    let repository: SQLiteClipboardRepository

    public var cleanupSettings = CleanupSettings()

    /// v0.10.8: 外部存储大小缓存（避免重复遍历文件系统）
    private var cachedExternalSize: (size: Int, timestamp: Date)?
    private let externalSizeCacheTTL: TimeInterval = 180  // 延长缓存，降低频繁遍历

    /// v0.22: 保护 cachedExternalSize 的锁，防止后台线程和主线程之间的数据竞争
    private let externalSizeCacheLock = NSLock()
    private var protectedExternalFilenameRefCounts: [String: Int] = [:]
    private var externalPayloadCommitGeneration: UInt64 = 0
    private var externalImageSourceLeaseReservations: [
        UUID: ExternalFileReservationRegistry.Reservation
    ] = [:]
    private var externalSizeSyncInterlock: (@Sendable (ExternalSizeSyncInterlockPoint) async -> Void)?
    private var orphanCleanupInterlock: (@Sendable (OrphanCleanupInterlockPoint) async -> Void)?
    private var ingestCommitInterlock: (@Sendable (IngestCommitInterlockPoint) async -> Void)?
    private var cleanupInterlock: (@Sendable (CleanupInterlockPoint) async -> Void)?

    /// 数据库文件路径（用于设置窗口显示）
    public var databaseFilePath: String { dbPath }

    // MARK: - Initialization

    public init(
        databasePath: String? = nil,
        storageRootURL: URL? = nil,
        fileOps: StorageFileOps = .live
    ) {
        let rootURL = Self.resolveRootDirectory(databasePath: databasePath, storageRootURL: storageRootURL)

        // v0.22: 改进目录创建错误处理 - 记录错误但不阻止初始化
        // 目录创建失败通常是权限问题，后续操作会有更具体的错误
        Self.createDirectoryIfNeeded(at: rootURL, description: "app directory")

        self.rootDirectory = rootURL
        self.dbPath = databasePath ?? rootURL.appendingPathComponent("clipboard.db").path
        let externalPath = rootURL.appendingPathComponent("content", isDirectory: true).path
        let thumbnailPath = rootURL.appendingPathComponent("thumbnails", isDirectory: true).path
        self.externalStoragePath = externalPath
        self.thumbnailCachePath = thumbnailPath
        self.externalStorageDirectoryPath = externalPath
        self.thumbnailCacheDirectoryPath = thumbnailPath
        self.ingestSpoolDirectoryPath = rootURL.appendingPathComponent("ingest", isDirectory: true).path
        self.fileOps = fileOps

        Self.createDirectoryIfNeeded(at: URL(fileURLWithPath: externalStoragePath), description: "external storage directory")
        Self.createDirectoryIfNeeded(at: URL(fileURLWithPath: thumbnailCachePath), description: "thumbnail cache directory")

        self.repository = SQLiteClipboardRepository(dbPath: self.dbPath)
    }

    func setExternalSizeSyncInterlockForTesting(
        _ interlock: (@Sendable (ExternalSizeSyncInterlockPoint) async -> Void)?
    ) {
        externalSizeSyncInterlock = interlock
    }

    func setOrphanCleanupInterlockForTesting(
        _ interlock: (@Sendable (OrphanCleanupInterlockPoint) async -> Void)?
    ) {
        orphanCleanupInterlock = interlock
    }

    func setIngestCommitInterlockForTesting(
        _ interlock: (@Sendable (IngestCommitInterlockPoint) async -> Void)?
    ) {
        ingestCommitInterlock = interlock
    }

    func setCleanupInterlockForTesting(
        _ interlock: (@Sendable (CleanupInterlockPoint) async -> Void)?
    ) {
        cleanupInterlock = interlock
    }

    private static func resolveRootDirectory(databasePath: String?, storageRootURL: URL?) -> URL {
        if let storageRootURL { return storageRootURL }

        if let databasePath, !databasePath.isEmpty, !isInMemoryDatabasePath(databasePath) {
            return URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        }

        if isRunningUnderTests() {
            return resolveTestRootDirectory(databasePath: databasePath)
        }

        if isInMemoryDatabasePath(databasePath ?? "") {
            return resolveEphemeralRootDirectory()
        }

        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("Scopy", isDirectory: true)
        }

        ScopyLog.storage.warning("Failed to resolve Application Support directory; falling back to temporary directory")
        return FileManager.default.temporaryDirectory.appendingPathComponent("Scopy", isDirectory: true)
    }

    private static func isRunningUnderTests() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
        {
            return true
        }

        // Hosted tests may not carry the typical env keys in some configurations.
        // Avoid touching user Application Support data when XCTest is present.
        return NSClassFromString("XCTestCase") != nil
    }

    private static func isInMemoryDatabasePath(_ databasePath: String) -> Bool {
        if databasePath == ":memory:" { return true }
        if databasePath.hasPrefix("file::memory:") { return true }
        if databasePath.contains("mode=memory") { return true }
        return false
    }

    private static let testRunIdentifier: String = {
        ProcessInfo.processInfo.environment["SCOPY_TEST_RUN_ID"]
            ?? String(ProcessInfo.processInfo.processIdentifier)
    }()

    private static func resolveTestRootDirectory(databasePath: String?) -> URL {
        if let databasePath, !databasePath.isEmpty, !isInMemoryDatabasePath(databasePath) {
            return URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopyTests", isDirectory: true)
            .appendingPathComponent(testRunIdentifier, isDirectory: true)
        return base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func resolveEphemeralRootDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopyTemp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func createDirectoryIfNeeded(at url: URL, description: String) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            ScopyLog.storage.warning("Failed to create \(description): \(error.localizedDescription, privacy: .private)")
        }
    }

    deinit {
        let repo = repository
        Task.detached {
            await repo.close()
        }
    }

    // MARK: - Database Lifecycle

    /// v0.11: 修复半打开状态问题 - 使用临时变量，失败时确保清理
    public func open() async throws {
        try await repository.open()
    }

    /// v0.11: 执行 WAL 检查点（定期调用以控制 WAL 文件大小）
    public func performWALCheckpoint() async {
        await repository.walCheckpointPassive()
    }

    /// v0.20: 关闭前执行 WAL 检查点，确保数据完整写入
    public func close() async {
        await repository.close()
    }

    // MARK: - CRUD Operations

    /// Insert or update item (handles deduplication per v0.md 3.2)
    /// v0.29: 大内容外部写入后台化，避免阻塞主线程
    public func upsertItem(_ content: ClipboardMonitor.ClipboardContent) async throws -> StoredItem {
        let outcome = try await upsertItemWithOutcome(content)
        guard let item = outcome.item else {
            throw StorageError.queryFailed("Previously applied ingest item no longer exists")
        }
        return item
    }

    func upsertItemWithOutcome(_ content: ClipboardMonitor.ClipboardContent) async throws -> UpsertOutcome {
        if let ingestID = content.ingestID {
            do {
                if try await repository.mightResolveIngestWithoutFileWork(
                    ingestID: ingestID,
                    contentHash: content.contentHash
                ) {
                    switch try await repository.commitExistingIngestIfPossible(
                        ingestID: ingestID,
                        contentHash: content.contentHash,
                        lastUsedAt: Date()
                    ) {
                    case .needsInsert:
                        break
                    case .updated(let item):
                        if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                            try? FileManager.default.removeItem(at: ingestURL)
                        }
                        return .updated(item)
                    case .alreadyApplied(let item):
                        if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                            try? FileManager.default.removeItem(at: ingestURL)
                        }
                        return .alreadyApplied(item)
                    }
                }
            } catch {
                if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                    try? FileManager.default.removeItem(at: ingestURL)
                }
                throw error
            }
        } else if let existing = try await repository.fetchItemByHash(content.contentHash) {
            // Update lastUsedAt and useCount instead of creating new. If deletion won after the
            // hash lookup, keep the ingest payload and continue through the insert path.
            if let updated = try await repository.incrementUsageReturningCurrent(
                id: existing.id,
                lastUsedAt: Date()
            ) {
                if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                    try? FileManager.default.removeItem(at: ingestURL)
                }
                return .updated(updated)
            }
        }

        let id = UUID()
        let now = Date()
        var storageRef: String? = nil
        var inlineData: Data? = nil
        var externalReservation: ExternalFileReservationRegistry.Reservation?
        var protectedExternalFilename: String?
        var repositoryCommitAttempted = false

        do {
            // Decide storage location based on size (v0.md 2.1). An external path is reserved
            // before publishing bytes and remains reserved through the DB insert, so orphan
            // cleanup cannot validate it as unreferenced and remove it in between.
            switch content.payload {
            case .none:
                inlineData = nil
            case .data(let data):
                if content.sizeBytes >= Self.externalStorageThreshold {
                    let path = makeExternalPath(id: id, type: content.type)
                    storageRef = path
                    let reservationKey = Self.externalReservationKey(forPath: path)
                    guard let reservation = await sharedExternalFileReservations.acquire(
                        resourceKeys: [reservationKey]
                    ) else {
                        throw CancellationError()
                    }
                    guard !Task.isCancelled else {
                        await sharedExternalFileReservations.release(reservation)
                        throw CancellationError()
                    }
                    externalReservation = reservation
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    protectedExternalFilename = filename
                    beginProtectingExternalFilename(filename)
                    try await Task.detached(priority: .utility) {
                        try StorageService.writeAtomically(data, to: path)
                    }.value
                } else {
                    inlineData = data
                }
            case .file(let url):
                if content.sizeBytes >= Self.externalStorageThreshold {
                    let path = makeExternalPath(id: id, type: content.type)
                    storageRef = path
                    let reservationKey = Self.externalReservationKey(forPath: path)
                    guard let reservation = await sharedExternalFileReservations.acquire(
                        resourceKeys: [reservationKey]
                    ) else {
                        throw CancellationError()
                    }
                    guard !Task.isCancelled else {
                        await sharedExternalFileReservations.release(reservation)
                        throw CancellationError()
                    }
                    externalReservation = reservation
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    protectedExternalFilename = filename
                    beginProtectingExternalFilename(filename)
                    try await Task.detached(priority: .utility) {
                        if content.fileOwnership == .durableSpool {
                            try StorageService.copyFileRetainingSource(from: url, to: path)
                        } else {
                            try StorageService.moveOrCopyFile(from: url, to: path)
                        }
                    }.value
                } else {
                    let data = try await Task.detached(priority: .utility) {
                        try Data(contentsOf: url)
                    }.value
                    inlineData = data
                    if content.fileOwnership == .transient {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }

            guard !Task.isCancelled else { throw CancellationError() }
            let outcome: UpsertOutcome
            if let ingestID = content.ingestID {
                repositoryCommitAttempted = true
                switch try await repository.upsertItemForIngest(
                    ingestID: ingestID,
                    id: id,
                    type: content.type,
                    contentHash: content.contentHash,
                    plainText: content.plainText,
                    note: content.note,
                    appBundleID: content.appBundleID,
                    createdAt: now,
                    lastUsedAt: now,
                    sizeBytes: content.sizeBytes,
                    fileSizeBytes: content.fileSizeBytes,
                    storageRef: storageRef,
                    rawData: inlineData
                ) {
                case .inserted(let item):
                    outcome = .inserted(item)
                case .updated(let item):
                    if let storageRef { try? FileManager.default.removeItem(atPath: storageRef) }
                    outcome = .updated(item)
                case .alreadyApplied(let item):
                    if let storageRef { try? FileManager.default.removeItem(atPath: storageRef) }
                    outcome = .alreadyApplied(item)
                }
            } else {
                try await repository.insertItem(
                    id: id,
                    type: content.type,
                    contentHash: content.contentHash,
                    plainText: content.plainText,
                    note: content.note,
                    appBundleID: content.appBundleID,
                    createdAt: now,
                    lastUsedAt: now,
                    sizeBytes: content.sizeBytes,
                    fileSizeBytes: content.fileSizeBytes,
                    storageRef: storageRef,
                    rawData: inlineData
                )
                outcome = .inserted(
                    StoredItem(
                        id: id,
                        type: content.type,
                        contentHash: content.contentHash,
                        plainText: content.plainText,
                        note: content.note,
                        appBundleID: content.appBundleID,
                        createdAt: now,
                        lastUsedAt: now,
                        useCount: 1,
                        isPinned: false,
                        sizeBytes: content.sizeBytes,
                        fileSizeBytes: content.fileSizeBytes,
                        storageRef: storageRef,
                        rawData: inlineData
                    )
                )
            }
            await releaseExternalPublicationGuards(
                protectedFilename: protectedExternalFilename,
                reservation: externalReservation
            )
            return outcome
        } catch {
            // A COMMIT error is not proof that SQLite rejected the transaction. Resolve by the
            // durable receipt before reclaiming the unique candidate, otherwise an ambiguous
            // success could leave a committed row pointing at a removed file. Keep both the
            // process-wide reservation and cleanup generation guard until that resolution is
            // complete so a reentrant orphan-cleanup pass cannot remove the candidate first.
            if let ingestID = content.ingestID, repositoryCommitAttempted {
                await ingestCommitInterlock?(
                    .beforeReceiptResolution(candidatePath: storageRef)
                )
                do {
                    switch try await repository.resolveExistingIngestReceipt(ingestID) {
                    case .missing:
                        break
                    case .alreadyApplied(let item):
                        if let storageRef, item?.storageRef != storageRef {
                            try? FileManager.default.removeItem(atPath: storageRef)
                        }
                        if content.fileOwnership == .transient,
                           let ingestURL = content.ingestFileURL,
                           ingestURL.path != item?.storageRef {
                            try? FileManager.default.removeItem(at: ingestURL)
                        }
                        await releaseExternalPublicationGuards(
                            protectedFilename: protectedExternalFilename,
                            reservation: externalReservation
                        )
                        guard let item else { return .alreadyApplied(nil) }
                        return item.id == id ? .inserted(item) : .updated(item)
                    }
                } catch {
                    // Preserve an unresolved candidate. The retained envelope and managed orphan
                    // reconciliation are safer than deleting bytes that an uncertain commit may own.
                    if content.fileOwnership == .transient,
                       let ingestURL = content.ingestFileURL,
                       ingestURL.path != storageRef {
                        try? FileManager.default.removeItem(at: ingestURL)
                    }
                    await releaseExternalPublicationGuards(
                        protectedFilename: protectedExternalFilename,
                        reservation: externalReservation
                    )
                    throw error
                }
            }
            // Best-effort rollback: DB insert failed after writing external payload.
            if let storageRef {
                try? FileManager.default.removeItem(atPath: storageRef)
            }
            if content.fileOwnership == .transient, let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            await releaseExternalPublicationGuards(
                protectedFilename: protectedExternalFilename,
                reservation: externalReservation
            )
            throw error
        }
    }

    private func releaseExternalPublicationGuards(
        protectedFilename: String?,
        reservation: ExternalFileReservationRegistry.Reservation?
    ) async {
        if let protectedFilename {
            endProtectingExternalFilename(protectedFilename)
        }
        if let reservation {
            await sharedExternalFileReservations.release(reservation)
        }
    }

    func removeIngestReceipt(_ ingestID: UUID) async throws {
        try await repository.removeIngestReceipt(ingestID)
    }

    public func findByHash(_ hash: String) async throws -> StoredItem? {
        try await repository.fetchItemByHash(hash)
    }

    public func findByID(_ id: UUID) async throws -> StoredItem? {
        try await repository.fetchItemByID(id)
    }

    /// Fetch recent items with pagination (v0.md 2.2)
    /// v0.13: 预分配数组容量，避免多次重新分配
    public func fetchRecent(limit: Int, offset: Int) async throws -> [StoredItem] {
        try await repository.fetchRecent(limit: limit, offset: offset)
    }

    public func fetchPinned() async throws -> [StoredItem] {
        try await repository.fetchPinned()
    }

    public func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [StoredItem] {
        try await repository.fetchRecentUnpinned(limit: limit, offset: offset)
    }

    func incrementUsage(id: UUID, at timestamp: Date) async throws -> StoredItem? {
        try await repository.incrementUsageReturningCurrent(id: id, lastUsedAt: timestamp)
    }

    func updateNote(id: UUID, note: String?) async throws -> StoredItem? {
        try await repository.updateItemNoteReturningItem(id: id, note: note)
    }

    func updateFileSizeBytes(
        expected: StoredItem,
        fileSizeBytes: Int?
    ) async throws -> StoredItem? {
        try await repository.updateItemFileSizeBytesReturningItem(
            expected: expected,
            fileSizeBytes: fileSizeBytes
        )
    }

    func updateItemPayload(
        id: UUID,
        contentHash: String,
        sizeBytes: Int,
        storageRef: String?,
        rawData: Data?
    ) async throws {
        try await repository.updateItemPayload(
            id: id,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            storageRef: storageRef,
            rawData: rawData
        )
    }

    /// Commits an asynchronously transformed payload only while the persisted row still matches
    /// the transform's input snapshot. Returns `nil` for deletion or same-ID replacement.
    func compareAndSwapItemPayload(
        expected: StoredItem,
        contentHash: String,
        sizeBytes: Int,
        storageRef: String?,
        rawData: Data?
    ) async throws -> StoredItem? {
        try await repository.compareAndSwapItemPayload(
            expected: expected,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            storageRef: storageRef,
            rawData: rawData
        )
    }

    /// Publishes a complete staged image through a unique managed path and then atomically swaps
    /// the database row from the caller's input snapshot to that path.
    ///
    /// The old shared path is never modified or eagerly deleted. Before CAS the new file is only
    /// an orphan; after CAS the row points to fully written immutable bytes. Full orphan cleanup
    /// owns eventual reclamation of the old path.
    func commitOptimizedExternalImagePayload(
        expected: StoredItem,
        stagedURL: URL,
        contentHash: String,
        sizeBytes: Int
    ) async throws -> StoredItem? {
        let finalURL = URL(fileURLWithPath: externalStoragePath, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).png")
        let finalFilename = finalURL.lastPathComponent

        let finalReservationKey = Self.externalReservationKey(forPath: finalURL.path)
        guard let reservation = await sharedExternalFileReservations.acquire(
            resourceKeys: [finalReservationKey]
        ) else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            await sharedExternalFileReservations.release(reservation)
            throw CancellationError()
        }
        beginProtectingExternalFilename(finalFilename)
        do {
            try Self.replaceFileAtomically(from: stagedURL, to: finalURL)
            let committedItem = try await repository.compareAndSwapItemPayload(
                expected: expected,
                contentHash: contentHash,
                sizeBytes: sizeBytes,
                storageRef: finalURL.path,
                rawData: nil
            )
            endProtectingExternalFilename(finalFilename)
            await sharedExternalFileReservations.release(reservation)

            guard let committedItem else {
                try? FileManager.default.removeItem(at: finalURL)
                return nil
            }

            invalidateExternalSizeCache()
            return committedItem
        } catch {
            endProtectingExternalFilename(finalFilename)
            await sharedExternalFileReservations.release(reservation)
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
    }

    func withExternalImageSourceLease<Result: Sendable>(
        sourceURL: URL,
        operation: @Sendable (ExternalImageSourceLease) async -> Result
    ) async -> Result? {
        guard Self.validateStorageRef(
            sourceURL.path,
            externalStoragePath: externalStorageDirectoryPath
        ) else {
            return nil
        }
        let filename = sourceURL.lastPathComponent
        let sourceReservationKey = Self.externalReservationKey(forPath: sourceURL.path)
        guard let reservation = await sharedExternalFileReservations.acquire(
            resourceKeys: [sourceReservationKey]
        ) else {
            return nil
        }
        guard !Task.isCancelled else {
            await sharedExternalFileReservations.release(reservation)
            return nil
        }
        let lease = ExternalImageSourceLease(
            id: UUID(),
            sourceReservationKey: sourceReservationKey
        )
        externalImageSourceLeaseReservations[lease.id] = reservation
        beginProtectingExternalFilename(filename)

        let result = await operation(lease)

        externalImageSourceLeaseReservations.removeValue(forKey: lease.id)
        endProtectingExternalFilename(filename)
        await sharedExternalFileReservations.release(reservation)
        return result
    }

    /// Reconciles an externally changed source while reserving both the source and the committed
    /// optimized file against orphan deletion. Every failed post-CAS verification restores the
    /// valid committed payload before another attempt or return.
    func reconcileExternalImageSourceOwnership(
        committedItem: StoredItem,
        sourceURL: URL,
        sourceLease: ExternalImageSourceLease,
        verificationInterlock: (@Sendable (_ attempt: Int) async -> Void)? = nil
    ) async -> ExternalSourceReconciliationResult {
        guard Self.validateStorageRef(
            sourceURL.path,
            externalStoragePath: externalStorageDirectoryPath
        ) else {
            return .failedOrUnstable
        }
        guard let optimizedRef = committedItem.storageRef,
              Self.validateStorageRef(
                optimizedRef,
                externalStoragePath: externalStorageDirectoryPath
              ) else {
            return .failedOrUnstable
        }

        guard sourceLease.sourceReservationKey == Self.externalReservationKey(forPath: sourceURL.path),
              externalImageSourceLeaseReservations[sourceLease.id] != nil else {
            return .failedOrUnstable
        }
        let protectedFilenames = [URL(fileURLWithPath: optimizedRef).lastPathComponent]
        let optimizedReservationKey = Self.externalReservationKey(forPath: optimizedRef)
        guard let reservation = await sharedExternalFileReservations.acquire(
            resourceKeys: [optimizedReservationKey]
        ) else {
            return .failedOrUnstable
        }
        guard !Task.isCancelled else {
            await sharedExternalFileReservations.release(reservation)
            return .failedOrUnstable
        }
        for filename in protectedFilenames {
            beginProtectingExternalFilename(filename)
        }

        let result = await performExternalSourceReconciliation(
            committedItem: committedItem,
            sourceURL: sourceURL,
            verificationInterlock: verificationInterlock
        )

        for filename in protectedFilenames {
            endProtectingExternalFilename(filename)
        }
        await sharedExternalFileReservations.release(reservation)
        return result
    }

    private func performExternalSourceReconciliation(
        committedItem: StoredItem,
        sourceURL: URL,
        verificationInterlock: (@Sendable (_ attempt: Int) async -> Void)?
    ) async -> ExternalSourceReconciliationResult {
        var expectedOptimized = committedItem
        for attempt in 0..<3 {
            let liveData: Data
            do {
                liveData = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                }.value
            } catch {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: sourceURL.path,
                    isDirectory: &isDirectory
                )
                if exists {
                    return .failedOrUnstable
                }
                // Only an initially absent source can prove that optimized bytes won without a
                // competing external write. Once any source adoption occurred, later removal is
                // part of an unstable race and must suppress optimized success proof.
                return attempt == 0 ? .sourceUnavailable : .failedOrUnstable
            }

            let liveHash = ClipboardMonitor.computeHashStatic(liveData)
            let reconciled: StoredItem
            do {
                guard let value = try await repository.compareAndSwapItemPayload(
                    expected: expectedOptimized,
                    contentHash: liveHash,
                    sizeBytes: liveData.count,
                    storageRef: sourceURL.path,
                    rawData: nil
                ) else {
                    return .failedOrUnstable
                }
                reconciled = value
            } catch {
                return .failedOrUnstable
            }

            await verificationInterlock?(attempt)
            let sourceIsStable: Bool
            do {
                let afterData = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                }.value
                sourceIsStable = afterData.count == liveData.count &&
                    ClipboardMonitor.computeHashStatic(afterData) == liveHash
            } catch {
                sourceIsStable = false
            }

            if sourceIsStable {
                return .adopted
            }

            // The source changed or disappeared after its payload won the CAS. Restore the known
            // valid optimized payload before retrying so the DB never exits pointing at an
            // unverified source.
            switch await restoreOptimizedPayloadAfterUnstableSource(
                reconciled: reconciled,
                committedItem: committedItem,
                sourceURL: sourceURL
            ) {
            case .restored(let repaired):
                expectedOptimized = repaired
            case .independentlySuperseded, .failed:
                return .failedOrUnstable
            }
        }
        ScopyLog.storage.warning("External image source kept changing during optimization reconciliation")
        return .failedOrUnstable
    }

    /// A size reconciliation can legitimately update `size_bytes` after source adoption but
    /// before the stability check finishes. Retry the repair from that newer source-lineage row;
    /// never leave a known-unstable source as the DB winner merely because the first CAS lost.
    private func restoreOptimizedPayloadAfterUnstableSource(
        reconciled: StoredItem,
        committedItem: StoredItem,
        sourceURL: URL
    ) async -> OptimizedPayloadRepairResult {
        var expected = reconciled
        for _ in 0..<8 {
            do {
                if let repaired = try await repository.compareAndSwapItemPayload(
                    expected: expected,
                    contentHash: committedItem.contentHash,
                    sizeBytes: committedItem.sizeBytes,
                    storageRef: committedItem.storageRef,
                    rawData: committedItem.rawData
                ) {
                    return .restored(repaired)
                }

                guard let current = try await repository.fetchItemByID(reconciled.id) else {
                    return .independentlySuperseded
                }
                guard current.type == reconciled.type,
                      current.plainText == reconciled.plainText,
                      current.storageRef == sourceURL.path else {
                    return .independentlySuperseded
                }
                expected = current
            } catch {
                return .failed
            }
        }
        return .failed
    }

    private func beginProtectingExternalFilename(_ filename: String) {
        protectedExternalFilenameRefCounts[filename, default: 0] += 1
        externalPayloadCommitGeneration &+= 1
    }

    private func endProtectingExternalFilename(_ filename: String) {
        guard let count = protectedExternalFilenameRefCounts[filename] else {
            externalPayloadCommitGeneration &+= 1
            return
        }
        if count <= 1 {
            protectedExternalFilenameRefCounts.removeValue(forKey: filename)
        } else {
            protectedExternalFilenameRefCounts[filename] = count - 1
        }
        externalPayloadCommitGeneration &+= 1
    }

    public func deleteItem(_ id: UUID) async throws {
        // DB-first: only delete external file after DB deletion succeeds.
        let storageRef = try await repository.deleteItemReturningStorageRef(id: id)

        guard let storageRef else { return }
        let externalRoot = externalStorageDirectoryPath
        guard StorageService.validateStorageRef(storageRef, externalStoragePath: externalRoot) else {
            ScopyLog.storage.warning("Refusing to delete invalid storageRef '\(storageRef, privacy: .private)'")
            return
        }

        let fileURL = URL(fileURLWithPath: storageRef)
        let remover = fileOps.removeFile
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                try remover(fileURL)
            } catch let error as NSError {
                // Ignore "file not found" (may be deleted concurrently).
                if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    return
                }
                ScopyLog.storage.warning(
                    "Failed to delete external file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                )
            } catch {
                ScopyLog.storage.warning(
                    "Failed to delete external file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                )
            }
        }.value
    }

    public func deleteAllExceptPinned() async throws {
        // DB-first: capture refs + delete rows in one transaction to avoid racey ref snapshots.
        // Keep this path separate from DeletePlan execution because the repository must atomically
        // capture every unpinned ref and delete without materializing every id in StorageService.
        let refs = try await repository.deleteAllExceptPinnedReturningStorageRefs()

        // Delete files off-main with bounded concurrency to avoid UI stalls and I/O storms.
        let fileURLs = validatedExternalFileURLs(from: refs, logContext: "clearAll")
        guard !fileURLs.isEmpty else {
            invalidateExternalSizeCache()
            return
        }
        let remover = fileOps.removeFile
        await Task.detached(priority: .utility) {
                await Self.deleteFilesBounded(
                    fileURLs,
                    maxConcurrent: Self.fileDeletionConcurrency(for: fileURLs.count),
                    logContext: "clearAll",
                    removeFile: remover
                )
        }.value
        invalidateExternalSizeCache()
    }

    private func validatedExternalFileURLs(from storageRefs: [String], logContext: StaticString) -> [URL] {
        guard !storageRefs.isEmpty else { return [] }

        let externalRoot = externalStorageDirectoryPath
        var urls: [URL] = []
        urls.reserveCapacity(storageRefs.count)

        var invalidCount = 0
        for ref in storageRefs {
            guard StorageService.validateStorageRef(ref, externalStoragePath: externalRoot) else {
                invalidCount += 1
                continue
            }
            urls.append(URL(fileURLWithPath: ref))
        }

        if invalidCount > 0 {
            ScopyLog.storage.warning(
                "[\(logContext)] Skipped \(invalidCount, privacy: .public) invalid storage refs"
            )
        }

        return urls
    }

    public func setPin(_ id: UUID, pinned: Bool) async throws {
        try await repository.updatePin(id: id, pinned: pinned)
    }

    // MARK: - Statistics

    public func getItemCount() async throws -> Int {
        try await repository.getItemCount()
    }

    public func getTotalSize() async throws -> Int {
        try await repository.getTotalSize()
    }

    /// v0.50.fix19: 同步外部图片的 `size_bytes` 与磁盘真实文件大小。
    ///
    /// 场景：用户在应用外部对 `content/` 目录批量压缩/覆盖图片后，
    /// DB 的 `size_bytes` 仍是旧值，会导致：
    /// - Footer “内容估算”显示偏大（甚至出现估算 > 磁盘的反直觉情况）
    /// - 按“内容估算上限”触发的自动清理误删
    ///
    /// 该方法只更新 `size_bytes`，不改变 `content_hash`（避免大规模重建缩略图/缓存）。
    func syncExternalImageSizeBytesFromDisk() async throws -> Int {
        let records = try await repository.fetchExternalStorageSizeRecords(typeFilter: .image)
        guard !records.isEmpty else { return 0 }

        let externalRoot = externalStorageDirectoryPath
        let updates = await Task.detached(priority: .utility) {
            var pending: [SQLiteClipboardRepository.SizeBytesUpdate] = []
            pending.reserveCapacity(records.count)
            let fm = FileManager.default

            for record in records {
                guard StorageService.validateStorageRef(record.storageRef, externalStoragePath: externalRoot) else {
                    continue
                }

                guard let attrs = try? fm.attributesOfItem(atPath: record.storageRef),
                      let fileSize = attrs[.size] as? Int,
                      fileSize > 0 else {
                    continue
                }

                guard fileSize != record.sizeBytes else { continue }
                pending.append(
                    SQLiteClipboardRepository.SizeBytesUpdate(
                        id: record.id,
                        expectedContentHash: record.contentHash,
                        expectedSizeBytes: record.sizeBytes,
                        expectedStorageRef: record.storageRef,
                        sizeBytes: fileSize
                    )
                )
            }

            return pending
        }.value

        guard !updates.isEmpty else { return 0 }
        await externalSizeSyncInterlock?(.afterStatBeforeCommit)
        let updatedCount = try await repository.updateItemSizeBytesBatchInTransaction(updates: updates)
        if updatedCount > 0 {
            invalidateExternalSizeCache()
        }
        return updatedCount
    }

    /// v0.10.8: 使用缓存避免重复遍历文件系统
    /// v0.22: 使用锁保护缓存访问，防止数据竞争
    public func getExternalStorageSize() async throws -> Int {
        // 检查缓存是否有效（加锁读取）
        if let cached = externalSizeCacheLock.withLock({ cachedExternalSize }),
           Date().timeIntervalSince(cached.timestamp) < externalSizeCacheTTL {
            return cached.size
        }

        if PerfFeatureFlags.externalSizeMetaFastPathEnabled {
            do {
                let size = try await repository.getExternalSize()
                externalSizeCacheLock.withLock {
                    cachedExternalSize = (size, Date())
                }
                return size
            } catch {
                ScopyLog.storage.warning(
                    "Failed to read external_size_bytes from meta, fallback to directory scan: \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        // 计算实际大小（后台计算，避免阻塞主线程）
        let path = externalStoragePath
        let size = try await Task.detached(priority: .utility) {
            try Self.calculateDirectorySize(at: path)
        }.value
        externalSizeCacheLock.withLock {
            cachedExternalSize = (size, Date())
        }
        return size
    }

    /// 静态目录大小计算，便于后台线程使用
    nonisolated private static func calculateDirectorySize(at path: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys)
        ) else {
            return 0
        }

        var totalSize = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  let size = resourceValues.fileSize else { continue }
            totalSize += size
        }
        return totalSize
    }

    /// v0.10.8: 使外部存储大小缓存失效
    /// v0.22: 使用锁保护缓存访问，防止数据竞争
    private func invalidateExternalSizeCache() {
        externalSizeCacheLock.withLock {
            cachedExternalSize = nil
        }
    }

    /// 获取数据库文件的实际磁盘大小（包含 WAL 和 SHM 文件）
    func getDatabaseFileSize() -> Int {
        let fm = FileManager.default
        var total = 0
        // SQLite WAL 模式会创建 .db-wal 和 .db-shm 文件
        for ext in ["", "-wal", "-shm"] {
            let path = dbPath + ext
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int {
                total += size
            }
        }
        return total
    }

    /// v0.15.2: 获取外部存储大小（强制刷新，不使用缓存）
    /// 用于 Settings 页面显示准确的存储统计（后台线程计算，避免阻塞主线程）
    func getExternalStorageSizeForStats() async throws -> Int {
        let path = externalStoragePath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let size = try Self.calculateDirectorySize(at: path)
                    continuation.resume(returning: size)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// v0.15.2: 获取缩略图缓存大小
    func getThumbnailCacheSize() async -> Int {
        let path = thumbnailCachePath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let url = URL(fileURLWithPath: path)
                let resourceKeys: Set<URLResourceKey> = [.fileSizeKey]

                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(resourceKeys)
                ) else {
                    continuation.resume(returning: 0)
                    return
                }

                var totalSize = 0
                for case let fileURL as URL in enumerator {
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                          let size = resourceValues.fileSize else { continue }
                    totalSize += size
                }
                continuation.resume(returning: totalSize)
            }
        }
    }

    /// 获取最近使用的 app 列表（用于过滤）
    public func getRecentApps(limit: Int) async throws -> [String] {
        try await repository.fetchRecentApps(limit: limit)
    }

    // MARK: - Cleanup (v0.md 2.3)

    public enum CleanupMode {
        case light   // 热路径：跳过 vacuum / orphan 扫描
        case full    // 低频：完整清理
    }

    @discardableResult
    public func performCleanup(mode: CleanupMode = .full) async throws -> CleanupResult {
        try await performCleanup(mode: mode, onCommitted: nil)
    }

    /// `onCommitted` is invoked after every independently committed delete phase. This prevents a
    /// later policy/read failure from hiding IDs that an earlier phase already removed from SQLite.
    @discardableResult
    func performCleanup(
        mode: CleanupMode,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        let cleanupImagesOnly = cleanupSettings.cleanupImagesOnly
        let modeText = (mode == .full) ? "full" : "light"
        let maxItems = cleanupSettings.maxItems
        let maxTotalMB = cleanupSettings.maxSmallStorageMB
        let maxExternalMB = cleanupSettings.maxLargeStorageMB
        let maxLargeBytes = maxExternalMB * 1024 * 1024
        ScopyLog.storage.info(
            "Cleanup start: mode=\(modeText, privacy: .public) imagesOnly=\(cleanupImagesOnly, privacy: .public) maxItems=\(maxItems, privacy: .public) maxTotalMB=\(maxTotalMB, privacy: .public) maxExternalMB=\(maxExternalMB, privacy: .public)"
        )
        var aggregateResult = CleanupResult.empty

        // 0. Composite path (count + external): reduce duplicated DB scans and delete passes.
        var currentCount = try await getItemCount()
        if PerfFeatureFlags.cleanupCompositePlanEnabled,
           currentCount > maxItems {
            let currentExternalSize = try await getExternalStorageSize()
            if currentExternalSize > maxLargeBytes {
                let compositeResult = try await cleanupCountAndExternalIfNeeded(
                    currentCount: currentCount,
                    externalSize: currentExternalSize,
                    maxItems: maxItems,
                    maxLargeBytes: maxLargeBytes,
                    cleanupImagesOnly: cleanupImagesOnly,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(compositeResult)
                if !compositeResult.deletedItemIDs.isEmpty {
                    currentCount = try await getItemCount()
                }
            }
        }

        // 1. By count
        if currentCount > maxItems {
            if cleanupImagesOnly {
                ScopyLog.storage.info(
                    "Cleanup by count (imagesOnly): current=\(currentCount, privacy: .public) max=\(maxItems, privacy: .public) delete=\(currentCount - maxItems, privacy: .public)"
                )
                let phaseResult = try await cleanupImagesOnlyByCount(
                    deleteCount: currentCount - maxItems,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            } else {
                ScopyLog.storage.info(
                    "Cleanup by count: current=\(currentCount, privacy: .public) max=\(maxItems, privacy: .public) target=\(maxItems, privacy: .public)"
                )
                let phaseResult = try await cleanupByCount(
                    target: maxItems,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            }
        }

        // 2. By age (if configured)
        if let maxDays = cleanupSettings.maxDaysAge {
            ScopyLog.storage.info(
                "Cleanup by age: maxDays=\(maxDays, privacy: .public) imagesOnly=\(cleanupImagesOnly, privacy: .public)"
            )
            if cleanupImagesOnly {
                let phaseResult = try await cleanupByAge(
                    maxDays: maxDays,
                    typeFilter: .image,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            } else {
                let phaseResult = try await cleanupByAge(
                    maxDays: maxDays,
                    typeFilter: nil,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            }
        }

        // 3. By space (small content / database)
        let dbSize = try await getTotalSize()
        let maxSmallBytes = cleanupSettings.maxSmallStorageMB * 1024 * 1024
        if dbSize > maxSmallBytes {
            ScopyLog.storage.info(
                "Cleanup by size: currentBytes=\(dbSize, privacy: .public) maxBytes=\(maxSmallBytes, privacy: .public) imagesOnly=\(cleanupImagesOnly, privacy: .public)"
            )
            if cleanupImagesOnly {
                let phaseResult = try await cleanupBySize(
                    targetBytes: maxSmallBytes,
                    typeFilter: .image,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            } else {
                let phaseResult = try await cleanupBySize(
                    targetBytes: maxSmallBytes,
                    typeFilter: nil,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            }
        }

        // 4. By space (large content / external storage) - v0.9
        let externalSize = try await getExternalStorageSize()
        if externalSize > maxLargeBytes {
            ScopyLog.storage.info(
                "Cleanup external storage: currentBytes=\(externalSize, privacy: .public) maxBytes=\(maxLargeBytes, privacy: .public) imagesOnly=\(cleanupImagesOnly, privacy: .public)"
            )
            if cleanupImagesOnly {
                let phaseResult = try await cleanupExternalStorage(
                    targetBytes: maxLargeBytes,
                    typeFilter: .image,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            } else {
                let phaseResult = try await cleanupExternalStorage(
                    targetBytes: maxLargeBytes,
                    typeFilter: nil,
                    onCommitted: onCommitted
                )
                aggregateResult = aggregateResult.merging(phaseResult)
            }
        }

        guard mode == .full else { return aggregateResult }

        // 5. SQLite housekeeping (v0.md 2.3)
        // v0.29: 仅在 WAL 体积明显膨胀时执行 vacuum，减少非敏感时段外的磁盘抖动
        let walSizeBytes = getWALFileSize()
        if walSizeBytes > 128 * 1024 * 1024 {
            try await repository.incrementalVacuum(pages: 100)
        }

        // 6. v0.15: Clean up orphaned files (files not referenced in database)
        try await cleanupOrphanedFiles()
        return aggregateResult
    }

    private func getWALFileSize() -> Int {
        let walPath = dbPath + "-wal"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
           let size = attrs[.size] as? NSNumber {
            return size.intValue
        }
        return 0
    }

    /// v0.15: Clean up orphaned files in external storage directory
    /// Files that exist on disk but have no corresponding database record
    /// This fixes the storage leak where files accumulate without being tracked
    /// v0.19: 修复 - 文件删除移到后台线程，避免阻塞主线程
    public func cleanupOrphanedFiles() async throws {
        if Self.isRunningUnderTests(), isAppSupportContentDirectory(externalStoragePath) {
            ScopyLog.storage.error("Refusing to cleanup orphaned files under Application Support during tests")
            return
        }

        if shouldRefuseOrphanCleanupForMismatchedDatabaseRoot() {
            return
        }

        // 1. Get all storage_ref filenames from database. Include a unique final file while its
        // payload CAS is awaiting the repository actor.
        let cleanupGeneration = externalPayloadCommitGeneration
        var validRefs = try await repository.fetchExternalRefFilenames()
        validRefs.formUnion(protectedExternalFilenameRefCounts.keys)

        // 2. Enumerate all files in content directory off-main (may traverse many files)
        let contentPath = externalStoragePath
        let orphanedFiles = await Task.detached(priority: .utility) {
            Self.findOrphanedExternalFiles(validRefs: validRefs, externalStoragePath: contentPath)
        }.value
        let staleOptimizationStages = await Task.detached(priority: .utility) {
            Self.staleImageOptimizationStageFiles(
                externalStoragePath: contentPath,
                now: Date(),
                maximumAge: 24 * 60 * 60
            )
        }.value
        await orphanCleanupInterlock?(.afterEnumerationBeforeOwnershipValidation)
        // A commit that began after this cleanup snapshot may have published a new unique file.
        // Abort this pass rather than deleting against stale ownership evidence.
        guard cleanupGeneration == externalPayloadCommitGeneration else { return }
        let filesToDelete = Array(Set(orphanedFiles + staleOptimizationStages))
        guard !filesToDelete.isEmpty else { return }

        // 3. Delete orphaned files with bounded concurrency (avoid I/O storms).
        let remover = fileOps.removeFile
        let reservations = sharedExternalFileReservations
        let repository = repository
        let removeInterlock = orphanCleanupInterlock
        await Task.detached(priority: .utility) {
            await Self.deleteOrphanFilesBounded(
                filesToDelete,
                maxConcurrent: Self.fileDeletionConcurrency(for: filesToDelete.count),
                repository: repository,
                reservations: reservations,
                beforeRemove: removeInterlock,
                removeFile: remover
            )
        }.value

        // 4. Invalidate cache after cleanup
        invalidateExternalSizeCache()
    }

    private func shouldRefuseOrphanCleanupForMismatchedDatabaseRoot() -> Bool {
        guard !Self.isInMemoryDatabasePath(dbPath) else { return false }

        let databaseDirectory = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let storageRoot = rootDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard databaseDirectory.path != storageRoot.path else { return false }

        ScopyLog.storage.error(
            "Refusing to cleanup orphaned files due to mismatched database/root directories (db=\(databaseDirectory.path, privacy: .private), root=\(storageRoot.path, privacy: .private))"
        )
        return true
    }

    private func isAppSupportContentDirectory(_ path: String) -> Bool {
        let contentURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            ScopyLog.storage.error("Unable to resolve Application Support directory; treating content directory as protected")
            return true
        }
        let expected = appSupport
            .appendingPathComponent("Scopy", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        return contentURL.path == expected.path || contentURL.path.hasPrefix(expected.path + "/")
    }

    nonisolated private static func findOrphanedExternalFiles(validRefs: Set<String>, externalStoragePath: String) -> [URL] {
        let contentURL = URL(fileURLWithPath: externalStoragePath)
        guard let enumerator = FileManager.default.enumerator(
            at: contentURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var orphanedFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            if !validRefs.contains(filename) {
                orphanedFiles.append(fileURL)
            }
        }
        return orphanedFiles
    }

    /// Hidden optimization and retained-source ingest stages are deliberately invisible to
    /// ordinary orphan enumeration so live work cannot be deleted. Reclaim only narrow filename
    /// patterns after a 24-hour crash-recovery horizon.
    nonisolated static func staleImageOptimizationStageFiles(
        externalStoragePath: String,
        now: Date,
        maximumAge: TimeInterval
    ) -> [URL] {
        let contentURL = URL(fileURLWithPath: externalStoragePath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: contentURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-max(1, maximumAge))
        return files.filter { url in
            let name = url.lastPathComponent
            let isOwnedStage = name.hasPrefix(".scopy-optimize-") ||
                name.hasPrefix(".scopy-ingest-")
            guard isOwnedStage, name.hasSuffix(".stage") else {
                return false
            }
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate else {
                return false
            }
            return modifiedAt <= cutoff
        }
    }

    private func cleanupCountAndExternalIfNeeded(
        currentCount: Int,
        externalSize: Int,
        maxItems: Int,
        maxLargeBytes: Int,
        cleanupImagesOnly: Bool,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        guard PerfFeatureFlags.cleanupCompositePlanEnabled else { return .empty }

        let deleteCount = max(0, currentCount - maxItems)
        let excessBytes = max(0, externalSize - maxLargeBytes)
        guard deleteCount > 0 || excessBytes > 0 else { return .empty }

        let countPlan: SQLiteClipboardRepository.DeletePlan
        if deleteCount > 0 {
            if cleanupImagesOnly {
                countPlan = try await repository.planCleanupUnpinnedImages(limit: deleteCount)
            } else {
                countPlan = try await repository.planCleanupByCount(target: maxItems)
            }
        } else {
            countPlan = .empty
        }

        let estimatedFreedByCount = try await repository.sumExternalBytes(ids: countPlan.ids)
        let remainingExcess = max(0, excessBytes - estimatedFreedByCount)
        let externalPlan: SQLiteClipboardRepository.DeletePlan
        if remainingExcess > 0 {
            externalPlan = try await repository.planCleanupExternalStorage(
                excessBytes: remainingExcess,
                typeFilter: cleanupImagesOnly ? .image : nil,
                excludingIDs: Set(countPlan.ids)
            )
        } else {
            externalPlan = .empty
        }

        if PerfFeatureFlags.cleanupShadowCompareEnabled {
            ScopyLog.storage.info(
                "Cleanup shadow compare: countPlan=\(countPlan.ids.count, privacy: .public) externalPlan=\(externalPlan.ids.count, privacy: .public) estimatedFreedByCount=\(estimatedFreedByCount, privacy: .public) remainingExcess=\(remainingExcess, privacy: .public)"
            )
        }

        let merged = SQLiteClipboardRepository.mergeDeletePlans([countPlan, externalPlan])
        guard !merged.ids.isEmpty else { return .empty }

        ScopyLog.storage.info(
            "cleanupComposite: deleting \(merged.ids.count, privacy: .public) items (count=\(countPlan.ids.count, privacy: .public), external=\(externalPlan.ids.count, privacy: .public), files=\(merged.storageRefs.count, privacy: .public), remainingExcess=\(remainingExcess, privacy: .public))"
        )
        return try await applyDeletePlan(
            merged,
            logContext: "cleanupComposite",
            onCommitted: onCommitted
        )
    }

    private func applyDeletePlan(
        _ plan: SQLiteClipboardRepository.DeletePlan,
        logContext: StaticString,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        guard !plan.ids.isEmpty else { return .empty }

        await cleanupInterlock?(.afterPlanBeforeCommit(plannedItemIDs: plan.ids))

        // DB-first: commit-time revalidation, ref capture, and deletion share one write transaction.
        let committed = try await repository.commitDeletePlan(plan)
        await cleanupInterlock?(
            .afterCommitBeforeFileCleanup(deletedItemIDs: committed.deletedItemIDs)
        )

        let committedResult = CleanupResult(
            plannedItemCount: committed.plannedCount,
            deletedItemIDs: committed.deletedItemIDs,
            skippedItemCount: committed.skippedCount,
            fileDeletionCandidateCount: 0,
            fileDeletionAttemptCount: 0,
            fileCleanupFailureCount: 0
        )
        if !committed.deletedItemIDs.isEmpty {
            await onCommitted?(committedResult)
        }

        let fileURLs = validatedExternalFileURLs(from: committed.storageRefs, logContext: logContext)
        let fileSummary: FileDeletionSummary
        guard !fileURLs.isEmpty else {
            invalidateExternalSizeCache()
            ScopyLog.storage.info(
                "[\(logContext)] Cleanup committed: planned=\(committed.plannedCount, privacy: .public) committed=\(committed.deletedItemIDs.count, privacy: .public) skipped=\(committed.skippedCount, privacy: .public) fileCandidates=0 fileAttempts=0 fileCleanupFailures=0"
            )
            return CleanupResult(
                plannedItemCount: committed.plannedCount,
                deletedItemIDs: committed.deletedItemIDs,
                skippedItemCount: committed.skippedCount,
                fileDeletionCandidateCount: 0,
                fileDeletionAttemptCount: 0,
                fileCleanupFailureCount: 0
            )
        }
        let remover = fileOps.removeFile
        let repository = repository
        let reservations = sharedExternalFileReservations
        fileSummary = await Task.detached(priority: .utility) {
            await Self.deleteCleanupFilesBounded(
                fileURLs,
                maxConcurrent: Self.fileDeletionConcurrency(for: fileURLs.count),
                repository: repository,
                reservations: reservations,
                logContext: logContext,
                removeFile: remover
            )
        }.value
        invalidateExternalSizeCache()
        ScopyLog.storage.info(
            "[\(logContext)] Cleanup committed: planned=\(committed.plannedCount, privacy: .public) committed=\(committed.deletedItemIDs.count, privacy: .public) skipped=\(committed.skippedCount, privacy: .public) fileCandidates=\(fileSummary.candidateCount, privacy: .public) fileAttempts=\(fileSummary.attemptedCount, privacy: .public) fileCleanupFailures=\(fileSummary.cleanupFailureCount, privacy: .public)"
        )
        return CleanupResult(
            plannedItemCount: committed.plannedCount,
            deletedItemIDs: committed.deletedItemIDs,
            skippedItemCount: committed.skippedCount,
            fileDeletionCandidateCount: fileSummary.candidateCount,
            fileDeletionAttemptCount: fileSummary.attemptedCount,
            fileCleanupFailureCount: fileSummary.cleanupFailureCount
        )
    }

    /// v0.14: 深度优化 - 消除子查询 COUNT，使用单次查询 + 事务批量删除
    /// 原理：先计算当前非 pin 数量，再用 OFFSET 直接定位要删除的记录
    /// 收益：消除 O(n) 子查询，50k 数据下节省 ~200ms
    private func cleanupByCount(
        target: Int,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        let plan = try await repository.planCleanupByCount(target: target)
        guard !plan.ids.isEmpty else { return .empty }
        ScopyLog.storage.info(
            "cleanupByCount: deleting \(plan.ids.count, privacy: .public) items (files=\(plan.storageRefs.count, privacy: .public)) target=\(target, privacy: .public)"
        )
        return try await applyDeletePlan(
            plan,
            logContext: "cleanupByCount",
            onCommitted: onCommitted
        )
    }

    private func cleanupImagesOnlyByCount(
        deleteCount: Int,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        let plan = try await repository.planCleanupUnpinnedImages(limit: deleteCount)
        guard !plan.ids.isEmpty else { return .empty }
        ScopyLog.storage.info(
            "cleanupImagesOnlyByCount: deleting \(plan.ids.count, privacy: .public) images (files=\(plan.storageRefs.count, privacy: .public)) requested=\(deleteCount, privacy: .public)"
        )
        return try await applyDeletePlan(
            plan,
            logContext: "cleanupImagesOnlyByCount",
            onCommitted: onCommitted
        )
    }

    /// v0.19: 修复 - 同时删除外部存储文件，避免孤立文件累积
    private func cleanupByAge(
        maxDays: Int,
        typeFilter: ClipboardItemType?,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        let cutoff = Date().addingTimeInterval(-Double(maxDays * 24 * 3600))
        let plan = try await repository.planCleanupByAge(cutoff: cutoff, typeFilter: typeFilter)
        guard !plan.ids.isEmpty else { return .empty }
        ScopyLog.storage.info(
            "cleanupByAge: deleting \(plan.ids.count, privacy: .public) items (files=\(plan.storageRefs.count, privacy: .public)) maxDays=\(maxDays, privacy: .public) type=\(String(describing: typeFilter), privacy: .public)"
        )
        return try await applyDeletePlan(
            plan,
            logContext: "cleanupByAge",
            onCommitted: onCommitted
        )
    }

    /// v0.14: 深度优化 - 消除循环迭代，单次查询 + 事务批量删除
    /// 原理：一次性获取所有待删除项目，累加 size 直到达到目标，单事务删除
    /// 收益：消除多次迭代的 SQL 开销，9000 条删除从 ~4500ms 降到 ~200ms
    private func cleanupBySize(
        targetBytes: Int,
        typeFilter: ClipboardItemType?,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        let plan = try await repository.planCleanupByTotalSize(targetBytes: targetBytes, typeFilter: typeFilter)
        guard !plan.ids.isEmpty else { return .empty }
        ScopyLog.storage.info(
            "cleanupBySize: deleting \(plan.ids.count, privacy: .public) items (files=\(plan.storageRefs.count, privacy: .public)) targetBytes=\(targetBytes, privacy: .public) type=\(String(describing: typeFilter), privacy: .public)"
        )
        return try await applyDeletePlan(
            plan,
            logContext: "cleanupBySize",
            onCommitted: onCommitted
        )
    }

    /// v0.13: 批量删除多个项目（单条 SQL，单事务，避免 N+1 查询）
    /// v0.14: 深度优化 - 消除循环迭代，单次查询 + 事务批量删除
    /// 原理：一次性获取所有外部存储项目，累加 size 直到达到目标，单事务删除
    /// 收益：消除多次迭代的 SQL 和文件系统开销
    private func cleanupExternalStorage(
        targetBytes: Int,
        typeFilter: ClipboardItemType?,
        onCommitted: CleanupCommitHandler?
    ) async throws -> CleanupResult {
        // 使缓存失效，确保获取最新大小
        invalidateExternalSizeCache()
        let currentSize = try await getExternalStorageSize()
        if currentSize <= targetBytes { return .empty }

        let excessBytes = currentSize - targetBytes
        let plan = try await repository.planCleanupExternalStorage(excessBytes: excessBytes, typeFilter: typeFilter)
        guard !plan.ids.isEmpty else { return .empty }
        ScopyLog.storage.info(
            "cleanupExternalStorage: deleting \(plan.ids.count, privacy: .public) items (files=\(plan.storageRefs.count, privacy: .public)) excessBytes=\(excessBytes, privacy: .public) type=\(String(describing: typeFilter), privacy: .public)"
        )
        return try await applyDeletePlan(
            plan,
            logContext: "cleanupExternalStorage",
            onCommitted: onCommitted
        )
    }

    nonisolated static func deleteFilesBounded(
        _ fileURLs: [URL],
        maxConcurrent: Int,
        logContext: StaticString,
        removeFile: @escaping FileRemover
    ) async {
        guard !fileURLs.isEmpty else { return }

        var uniquePaths: [String] = []
        uniquePaths.reserveCapacity(fileURLs.count)
        var seen = Set<String>()
        seen.reserveCapacity(fileURLs.count)
        for url in fileURLs {
            if seen.insert(url.path).inserted {
                uniquePaths.append(url.path)
            }
        }

        let uniquePathsSnapshot = uniquePaths
        let workerCount = min(max(1, maxConcurrent), uniquePathsSnapshot.count)
        let chunkSize = max(64, (uniquePathsSnapshot.count + workerCount - 1) / workerCount)

        await withTaskGroup(of: Void.self) { group in
            for start in stride(from: 0, to: uniquePathsSnapshot.count, by: chunkSize) {
                let end = min(start + chunkSize, uniquePathsSnapshot.count)
                let chunkPaths = Array(uniquePathsSnapshot[start..<end])
                group.addTask {
                    for path in chunkPaths {
                        let fileURL = URL(fileURLWithPath: path)
                        do {
                            try removeFile(fileURL)
                        } catch let error as NSError {
                            // Ignore "file not found" (may be deleted concurrently).
                            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                                continue
                            }
                            ScopyLog.storage.warning(
                                "[\(logContext)] Failed to delete file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                            )
                        } catch {
                            ScopyLog.storage.warning(
                                "[\(logContext)] Failed to delete file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// Deletes only refs still unowned after the cleanup transaction. Each bounded chunk holds
    /// process-wide path reservations and performs one batch repository lookup, preserving orphan
    /// safety without two serialized SQLite actor hops per file.
    private nonisolated static func deleteCleanupFilesBounded(
        _ fileURLs: [URL],
        maxConcurrent: Int,
        repository: SQLiteClipboardRepository,
        reservations: ExternalFileReservationRegistry,
        logContext: StaticString,
        removeFile: @escaping FileRemover
    ) async -> FileDeletionSummary {
        guard !fileURLs.isEmpty else { return .empty }
        let uniqueURLs = Dictionary(
            fileURLs.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }
        let workerCount = min(max(1, maxConcurrent), uniqueURLs.count)
        let chunkSize = max(128, (uniqueURLs.count + workerCount - 1) / workerCount)

        return await withTaskGroup(of: FileDeletionSummary.self) { group in
            for start in stride(from: 0, to: uniqueURLs.count, by: chunkSize) {
                let end = min(start + chunkSize, uniqueURLs.count)
                let chunk = Array(uniqueURLs[start..<end])
                group.addTask {
                    let reservationKeys = chunk.map { externalReservationKey(forPath: $0.path) }
                    guard let reservation = await reservations.acquire(resourceKeys: reservationKeys) else {
                        return FileDeletionSummary(
                            candidateCount: chunk.count,
                            attemptedCount: 0,
                            cleanupFailureCount: chunk.count
                        )
                    }

                    let unreferenced: Set<String>
                    do {
                        unreferenced = try await repository.unreferencedStorageRefs(chunk.map(\.path))
                    } catch {
                        await reservations.release(reservation)
                        ScopyLog.storage.warning(
                            "[\(logContext)] Failed to verify cleanup file ownership: \(error.localizedDescription, privacy: .private)"
                        )
                        return FileDeletionSummary(
                            candidateCount: chunk.count,
                            attemptedCount: 0,
                            cleanupFailureCount: chunk.count
                        )
                    }

                    var attemptedCount = 0
                    var cleanupFailureCount = 0
                    for fileURL in chunk where unreferenced.contains(fileURL.path) {
                        attemptedCount += 1
                        do {
                            try removeFile(fileURL)
                        } catch let error as NSError {
                            if error.domain == NSCocoaErrorDomain &&
                                error.code == NSFileNoSuchFileError {
                                continue
                            }
                            cleanupFailureCount += 1
                            ScopyLog.storage.warning(
                                "[\(logContext)] Failed to delete file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                            )
                        } catch {
                            cleanupFailureCount += 1
                            ScopyLog.storage.warning(
                                "[\(logContext)] Failed to delete file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                            )
                        }
                    }
                    await reservations.release(reservation)
                    return FileDeletionSummary(
                        candidateCount: chunk.count,
                        attemptedCount: attemptedCount,
                        cleanupFailureCount: cleanupFailureCount
                    )
                }
            }

            var candidateCount = 0
            var attemptedCount = 0
            var cleanupFailureCount = 0
            for await summary in group {
                candidateCount += summary.candidateCount
                attemptedCount += summary.attemptedCount
                cleanupFailureCount += summary.cleanupFailureCount
            }
            return FileDeletionSummary(
                candidateCount: candidateCount,
                attemptedCount: attemptedCount,
                cleanupFailureCount: cleanupFailureCount
            )
        }
    }

    private nonisolated static func deleteOrphanFilesBounded(
        _ fileURLs: [URL],
        maxConcurrent: Int,
        repository: SQLiteClipboardRepository,
        reservations: ExternalFileReservationRegistry,
        beforeRemove: (@Sendable (OrphanCleanupInterlockPoint) async -> Void)?,
        removeFile: @escaping FileRemover
    ) async {
        guard !fileURLs.isEmpty else { return }
        let uniqueURLs = Dictionary(
            fileURLs.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }
        let workerCount = min(max(1, maxConcurrent), uniqueURLs.count)
        let chunkSize = max(1, (uniqueURLs.count + workerCount - 1) / workerCount)

        await withTaskGroup(of: Void.self) { group in
            for start in stride(from: 0, to: uniqueURLs.count, by: chunkSize) {
                let end = min(start + chunkSize, uniqueURLs.count)
                let chunk = Array(uniqueURLs[start..<end])
                group.addTask {
                    for fileURL in chunk {
                        let reservationKey = externalReservationKey(forPath: fileURL.path)
                        guard let reservation = await reservations.acquire(
                            resourceKeys: [reservationKey]
                        ) else {
                            continue
                        }
                        guard !Task.isCancelled else {
                            await reservations.release(reservation)
                            continue
                        }

                        let wasReferenced = (try? await repository.isStorageRefReferenced(fileURL.path)) ?? true
                        if !wasReferenced {
                            await beforeRemove?(
                                .afterOwnershipValidationBeforeRemove(path: fileURL.path)
                            )
                            let isNowReferenced = (try? await repository.isStorageRefReferenced(fileURL.path)) ?? true
                            if !isNowReferenced {
                                await beforeRemove?(
                                    .afterFinalOwnershipValidationBeforeRemove(path: fileURL.path)
                                )
                                do {
                                    try removeFile(fileURL)
                                } catch let error as NSError {
                                    if !(error.domain == NSCocoaErrorDomain &&
                                        error.code == NSFileNoSuchFileError) {
                                        ScopyLog.storage.warning(
                                            "[orphanCleanup] Failed to delete file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                                        )
                                    }
                                } catch {
                                    ScopyLog.storage.warning(
                                        "[orphanCleanup] Failed to delete file '\(fileURL.path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                                    )
                                }
                            }
                        }
                        await reservations.release(reservation)
                    }
                }
            }
        }
    }

    private nonisolated static func externalReservationKey(forPath path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated static func fileDeletionConcurrency(for fileCount: Int) -> Int {
        let base = max(1, maxConcurrentFileDeletions)
        guard fileCount > 0 else { return base }

        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        if fileCount >= 8_192 {
            return min(128, max(base, cores * 8))
        }
        if fileCount >= 2_048 {
            return min(96, max(base, cores * 6))
        }
        if fileCount >= 512 {
            return min(64, max(base, cores * 4))
        }
        return base
    }

    nonisolated static func fastRemoveFile(_ url: URL) throws {
        let path = url.path
        let result = path.withCString { cPath in
            unlink(cPath)
        }
        if result == 0 {
            return
        }

        let code = errno
        if code == ENOENT {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        // Fall back for directory-like paths or permission edge cases.
        if code == EISDIR || code == EPERM {
            try FileManager.default.removeItem(at: url)
            return
        }

        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    // MARK: - External Storage

    /// v0.17: 原子文件写入 - 使用临时文件 + 重命名，避免崩溃时文件损坏
    nonisolated static func writeAtomically(_ data: Data, to path: String) throws {
        let tempPath = path + ".tmp"
        let tempURL = URL(fileURLWithPath: tempPath)
        let finalURL = URL(fileURLWithPath: path)

        // 写入临时文件
        try data.write(to: tempURL)

        // 如果目标文件存在，先删除
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: finalURL)
        }

        // 原子重命名
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }

    /// Atomically moves a fully prepared file to its unique managed destination on the same
    /// filesystem.
    nonisolated static func replaceFileAtomically(
        from stagedURL: URL,
        to destinationURL: URL
    ) throws {
        guard Darwin.rename(stagedURL.path, destinationURL.path) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSFilePathErrorKey: destinationURL.path,
                    NSDebugDescriptionErrorKey: "Failed to atomically publish staged payload"
                ]
            )
        }
    }

    nonisolated static func moveOrCopyFile(from sourceURL: URL, to destinationPath: String) throws {
        let destinationURL = URL(fileURLWithPath: destinationPath)

        if FileManager.default.fileExists(atPath: destinationPath) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            let data = try Data(contentsOf: sourceURL)
            try writeAtomically(data, to: destinationPath)
            BestEffortFileOps.removeItem(
                at: sourceURL,
                logger: ScopyLog.storage,
                operation: "moveOrCopyFile.cleanupSourceAfterCopy"
            )
        }
    }

    /// Publishes a complete candidate while keeping a durable replay source untouched until the
    /// caller has committed and terminally acknowledged its ingest envelope.
    nonisolated static func copyFileRetainingSource(
        from sourceURL: URL,
        to destinationPath: String
    ) throws {
        let destinationURL = URL(fileURLWithPath: destinationPath)
        let stagedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".scopy-ingest-\(UUID().uuidString).stage"
        )
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        guard !FileManager.default.fileExists(atPath: destinationPath) else {
            throw StorageError.fileOperationFailed("Managed ingest destination already exists")
        }
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        try replaceFileAtomically(from: stagedURL, to: destinationURL)
    }

    private func makeExternalPath(id: UUID, type: ClipboardItemType) -> String {
        let ext: String
        switch type {
        case .image: ext = "png"
        case .rtf: ext = "rtf"
        case .html: ext = "html"
        default: ext = "dat"
        }

        let filename = "\(id.uuidString).\(ext)"
        return (externalStoragePath as NSString).appendingPathComponent(filename)
    }

    /// v0.22: 外部文件加载最大大小限制 (100MB)
    /// 防止恶意或损坏的文件导致内存耗尽
    nonisolated private static let maxExternalFileSize: Int = 100 * 1024 * 1024

    nonisolated static func validateStorageRef(_ ref: String, externalStoragePath: String) -> Bool {
        let filename = (ref as NSString).lastPathComponent
        let nameWithoutExt = (filename as NSString).deletingPathExtension

        guard UUID(uuidString: nameWithoutExt) != nil else {
            return false
        }

        guard !ref.contains("..") && !filename.contains("/") else {
            return false
        }

        let standardizedRefPath = URL(fileURLWithPath: ref).standardizedFileURL.path
        let standardizedAllowedPath = URL(fileURLWithPath: externalStoragePath).standardizedFileURL.path
        guard standardizedRefPath.hasPrefix(standardizedAllowedPath + "/") else {
            return false
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: ref, isDirectory: &isDirectory)
        if exists {
            if isDirectory.boolValue {
                return false
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: ref),
               let fileType = attrs[.type] as? FileAttributeType,
               fileType == .typeSymbolicLink {
                return false
            }

            let url = URL(fileURLWithPath: ref)
            let resolvedPath = url.resolvingSymlinksInPath().path
            let allowedPath = URL(fileURLWithPath: externalStoragePath).resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(allowedPath + "/") else {
                return false
            }
        }

        return true
    }

    nonisolated private static func loadExternalData(path: String, externalStoragePath: String) throws -> Data {
        guard validateStorageRef(path, externalStoragePath: externalStoragePath) else {
            throw StorageError.fileOperationFailed("Invalid storage reference: potential path traversal")
        }

        let url = URL(fileURLWithPath: path)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attrs[.size] as? Int, fileSize > maxExternalFileSize {
                throw StorageError.fileOperationFailed("File too large: \(fileSize) bytes (max: \(maxExternalFileSize))")
            }
        } catch let error as StorageError {
            throw error
        } catch {
            ScopyLog.storage.warning("Failed to get file attributes: \(error.localizedDescription, privacy: .private)")
        }

        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw StorageError.fileOperationFailed("Failed to read external file: \(error)")
        }
    }

    // MARK: - Thumbnail Cache (v0.8)

    /// 获取缩略图路径（如果存在）
    func getThumbnailPath(for contentHash: String) -> String? {
        let path = (thumbnailCachePath as NSString).appendingPathComponent("\(contentHash).png")
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    /// 获取文件缩略图路径（如果存在）
    func getFileThumbnailPath(for contentHash: String) -> String? {
        let filename = Self.fileThumbnailFilename(for: contentHash)
        let path = (thumbnailCachePath as NSString).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated static func fileThumbnailFilename(for contentHash: String) -> String {
        "file_\(contentHash).png"
    }

    /// 保存缩略图
    func saveThumbnail(_ data: Data, for contentHash: String) async throws -> String {
        let path = (thumbnailCachePath as NSString).appendingPathComponent("\(contentHash).png")
        do {
            try await Task.detached(priority: .utility) {
                try Self.writeAtomically(data, to: path)
            }.value
            return path
        } catch {
            throw StorageError.fileOperationFailed("Failed to save thumbnail: \(error)")
        }
    }

    /// 生成缩略图 PNG 数据（后台安全）
    /// 使用 ImageIO downsample + 编码，避免 AppKit 绘制/锁屏开销
    nonisolated static func makeThumbnailPNG(from imageData: Data, maxHeight: Int) -> Data? {
        guard maxHeight > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }

        var maxPixelSize = CGFloat(maxHeight)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0, height > 0 {
            let scale = CGFloat(maxHeight) / height
            maxPixelSize = max(width * scale, CGFloat(maxHeight))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded(.up)),
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 生成缩略图 PNG 数据（文件路径版本，后台安全）
    /// - Note: 优先走 ImageIO + URL，避免读入完整 Data（对外部存储大图片更省内存/更快）。
    nonisolated static func makeThumbnailPNG(fromFileAtPath path: String, maxHeight: Int) -> Data? {
        guard maxHeight > 0 else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        var maxPixelSize = CGFloat(maxHeight)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0, height > 0
        {
            let scale = CGFloat(maxHeight) / height
            maxPixelSize = max(width * scale, CGFloat(maxHeight))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded(.up)),
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Load raw payload data for a stored item.
    ///
    /// Notes:
    /// - This is used by image/rtf/html/file restore paths.
    /// - When `rawData` is nil (e.g. memory-optimized summaries), this falls back to reloading from DB.
    func loadPayloadData(for item: StoredItem) async -> Data? {
        // 1. 优先使用外部存储（大图片 >100KB）
        if let storageRef = item.storageRef {
            let allowedRoot = externalStoragePath
            return await Task.detached(priority: .userInitiated) {
                try? Self.loadExternalData(path: storageRef, externalStoragePath: allowedRoot)
            }.value
        }

        // 2. 使用内联数据（小图片）
        if let rawData = item.rawData {
            return rawData
        }

        // 3. 从数据库重新加载（缓存中 rawData 为 nil 的情况）
        // 这是 v0.19 内存优化导致的问题：缓存中的 rawData 被设为 nil
        if let freshItem = try? await findByID(item.id), let rawData = freshItem.rawData {
            return rawData
        }

        ScopyLog.storage.error("Failed to get original image data for item \(item.id.uuidString, privacy: .public)")
        return nil
    }

    @available(*, deprecated, message: "Use loadPayloadData(for:) (this method name was misleading).")
    func getOriginalImageData(for item: StoredItem) async -> Data? {
        await loadPayloadData(for: item)
    }

    /// 清空缩略图缓存（设置变更时调用）
    func clearThumbnailCache() async {
        let path = thumbnailCachePath
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try? fileManager.removeItem(atPath: path)
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }.value
    }

    /// 清理缩略图缓存（LRU 策略）
    func cleanupThumbnailCache(maxSizeMB: Int = 50) {
        let maxBytes = maxSizeMB * 1024 * 1024
        let url = URL(fileURLWithPath: thumbnailCachePath)

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]
        ) else { return }

        var files: [(url: URL, size: Int, accessDate: Date)] = []
        var totalSize = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]),
                  let size = values.fileSize,
                  let accessDate = values.contentAccessDate else { continue }
            files.append((fileURL, size, accessDate))
            totalSize += size
        }

        // 如果超出限制，按访问时间排序删除最旧的
        if totalSize > maxBytes {
            files.sort { $0.accessDate < $1.accessDate }
            for file in files {
                if totalSize <= maxBytes { break }
                try? FileManager.default.removeItem(at: file.url)
                totalSize -= file.size
            }
        }
    }

}
