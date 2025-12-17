import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

        var item: StoredItem {
            switch self {
            case .inserted(let item): return item
            case .updated(let item): return item
            }
        }
    }

    // MARK: - Configuration

    /// Threshold for external storage (v0.md: 小内容 < X KB)
    static let externalStorageThreshold = ScopyThresholds.externalStorageBytes

    /// Concurrency limit for bulk filesystem deletions (avoid I/O storms).
    static let maxConcurrentFileDeletions = 8

    typealias FileRemover = @Sendable (URL) throws -> Void

    #if DEBUG
    nonisolated(unsafe) static var fileRemoverForTesting: FileRemover?
    #endif

    /// Default cleanup settings (v0.md 2.1)
    public struct CleanupSettings {
        public var maxItems: Int = 10_000
        public var maxDaysAge: Int? = nil // nil = unlimited
        public var maxSmallStorageMB: Int = 200
        public var maxLargeStorageMB: Int = 800

        public init() {}
    }

    // MARK: - Properties

    private let dbPath: String
    private let rootDirectory: URL
    private let externalStoragePath: String
    private let thumbnailCachePath: String

    /// Exposed as immutable values so non-`@MainActor` contexts can safely validate/read paths without capturing `StorageService`.
    nonisolated let externalStorageDirectoryPath: String
    nonisolated let thumbnailCacheDirectoryPath: String

    let repository: SQLiteClipboardRepository

    public var cleanupSettings = CleanupSettings()

    /// v0.10.8: 外部存储大小缓存（避免重复遍历文件系统）
    private var cachedExternalSize: (size: Int, timestamp: Date)?
    private let externalSizeCacheTTL: TimeInterval = 180  // 延长缓存，降低频繁遍历

    /// v0.22: 保护 cachedExternalSize 的锁，防止后台线程和主线程之间的数据竞争
    private let externalSizeCacheLock = NSLock()

    /// 数据库文件路径（用于设置窗口显示）
    public var databaseFilePath: String { dbPath }

    // MARK: - Initialization

    public init(databasePath: String? = nil, storageRootURL: URL? = nil) {
        let rootURL = Self.resolveRootDirectory(databasePath: databasePath, storageRootURL: storageRootURL)

        // v0.22: 改进目录创建错误处理 - 记录错误但不阻止初始化
        // 目录创建失败通常是权限问题，后续操作会有更具体的错误
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            ScopyLog.storage.warning("Failed to create app directory: \(error.localizedDescription, privacy: .private)")
        }

        self.rootDirectory = rootURL
        self.dbPath = databasePath ?? rootURL.appendingPathComponent("clipboard.db").path
        let externalPath = rootURL.appendingPathComponent("content", isDirectory: true).path
        let thumbnailPath = rootURL.appendingPathComponent("thumbnails", isDirectory: true).path
        self.externalStoragePath = externalPath
        self.thumbnailCachePath = thumbnailPath
        self.externalStorageDirectoryPath = externalPath
        self.thumbnailCacheDirectoryPath = thumbnailPath

        do {
            try FileManager.default.createDirectory(atPath: externalStoragePath, withIntermediateDirectories: true)
        } catch {
            ScopyLog.storage.warning("Failed to create external storage directory: \(error.localizedDescription, privacy: .private)")
        }

        do {
            try FileManager.default.createDirectory(atPath: thumbnailCachePath, withIntermediateDirectories: true)
        } catch {
            ScopyLog.storage.warning("Failed to create thumbnail cache directory: \(error.localizedDescription, privacy: .private)")
        }

        self.repository = SQLiteClipboardRepository(dbPath: self.dbPath)
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
        try await upsertItemWithOutcome(content).item
    }

    func upsertItemWithOutcome(_ content: ClipboardMonitor.ClipboardContent) async throws -> UpsertOutcome {
        // Check for duplicate by content hash (v0.md 3.2)
        if let existing = try await repository.fetchItemByHash(content.contentHash) {
            if let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }

            // Update lastUsedAt and useCount instead of creating new
            var updated = existing
            updated.lastUsedAt = Date()
            updated.useCount += 1
            try await repository.updateUsage(id: updated.id, lastUsedAt: updated.lastUsedAt, useCount: updated.useCount)
            return .updated(updated)
        }

        let id = UUID()
        let now = Date()
        var storageRef: String? = nil
        var inlineData: Data? = nil

        // Decide storage location based on size (v0.md 2.1)
        switch content.payload {
        case .none:
            inlineData = nil
        case .data(let data):
            if content.sizeBytes >= Self.externalStorageThreshold {
                let path = makeExternalPath(id: id, type: content.type)
                try await Task.detached(priority: .utility) {
                    try StorageService.writeAtomically(data, to: path)
                }.value
                storageRef = path
            } else {
                inlineData = data
            }
        case .file(let url):
            if content.sizeBytes >= Self.externalStorageThreshold {
                let path = makeExternalPath(id: id, type: content.type)
                try await Task.detached(priority: .utility) {
                    try StorageService.moveOrCopyFile(from: url, to: path)
                }.value
                storageRef = path
            } else {
                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url)
                }.value
                inlineData = data
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            try await repository.insertItem(
                id: id,
                type: content.type,
                contentHash: content.contentHash,
                plainText: content.plainText,
                appBundleID: content.appBundleID,
                createdAt: now,
                lastUsedAt: now,
                sizeBytes: content.sizeBytes,
                storageRef: storageRef,
                rawData: inlineData
            )
        } catch {
            // Best-effort rollback: DB insert failed after writing external payload.
            if let storageRef {
                try? FileManager.default.removeItem(atPath: storageRef)
            }
            if let ingestURL = content.ingestFileURL {
                try? FileManager.default.removeItem(at: ingestURL)
            }
            throw error
        }

        return .inserted(
            StoredItem(
                id: id,
                type: content.type,
                contentHash: content.contentHash,
                plainText: content.plainText,
                appBundleID: content.appBundleID,
                createdAt: now,
                lastUsedAt: now,
                useCount: 1,
                isPinned: false,
                sizeBytes: content.sizeBytes,
                storageRef: storageRef,
                rawData: inlineData
            )
        )
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

    func updateItem(_ item: StoredItem) async throws {
        try await repository.updateItemMetadata(
            id: item.id,
            lastUsedAt: item.lastUsedAt,
            useCount: item.useCount,
            isPinned: item.isPinned
        )
    }

    public func deleteItem(_ id: UUID) async throws {
        // First get the item to clean up external storage
        // v0.19: 添加错误日志
        if let item = try await repository.fetchItemByID(id), let storageRef = item.storageRef {
            do {
                try FileManager.default.removeItem(atPath: storageRef)
            } catch {
                ScopyLog.storage.warning(
                    "Failed to delete external file '\(storageRef, privacy: .private)': \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        try await repository.deleteItem(id: id)
    }

    public func deleteAllExceptPinned() async throws {
        let refs = try await repository.fetchStorageRefsForUnpinned()

        // Delete files off-main with bounded concurrency to avoid UI stalls and I/O storms.
        let fileURLs = refs.map { URL(fileURLWithPath: $0) }
        await Task.detached(priority: .utility) {
            await Self.deleteFilesBounded(
                fileURLs,
                maxConcurrent: Self.maxConcurrentFileDeletions,
                logContext: "clearAll"
            )
        }.value

        // Delete from DB
        try await repository.deleteAllExceptPinned()
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

    /// v0.10.8: 使用缓存避免重复遍历文件系统
    /// v0.22: 使用锁保护缓存访问，防止数据竞争
    public func getExternalStorageSize() async throws -> Int {
        // 检查缓存是否有效（加锁读取）
        if let cached = externalSizeCacheLock.withLock({ cachedExternalSize }),
           Date().timeIntervalSince(cached.timestamp) < externalSizeCacheTTL {
            return cached.size
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

    public func performCleanup(mode: CleanupMode = .full) async throws {
        // 1. By count
        let currentCount = try await getItemCount()
        if currentCount > cleanupSettings.maxItems {
            try await cleanupByCount(target: cleanupSettings.maxItems)
        }

        // 2. By age (if configured)
        if let maxDays = cleanupSettings.maxDaysAge {
            try await cleanupByAge(maxDays: maxDays)
        }

        // 3. By space (small content / database)
        let dbSize = try await getTotalSize()
        let maxSmallBytes = cleanupSettings.maxSmallStorageMB * 1024 * 1024
        if dbSize > maxSmallBytes {
            try await cleanupBySize(targetBytes: maxSmallBytes)
        }

        // 4. By space (large content / external storage) - v0.9
        let externalSize = try await getExternalStorageSize()
        let maxLargeBytes = cleanupSettings.maxLargeStorageMB * 1024 * 1024
        if externalSize > maxLargeBytes {
            try await cleanupExternalStorage(targetBytes: maxLargeBytes)
        }

        guard mode == .full else { return }

        // 5. SQLite housekeeping (v0.md 2.3)
        // v0.29: 仅在 WAL 体积明显膨胀时执行 vacuum，减少非敏感时段外的磁盘抖动
        let walSizeBytes = getWALFileSize()
        if walSizeBytes > 128 * 1024 * 1024 {
            try await repository.incrementalVacuum(pages: 100)
        }

        // 6. v0.15: Clean up orphaned files (files not referenced in database)
        try await cleanupOrphanedFiles()
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

        // 1. Get all storage_ref filenames from database
        let validRefs = try await repository.fetchExternalRefFilenames()

        // 2. Enumerate all files in content directory off-main (may traverse many files)
        let contentPath = externalStoragePath
        let orphanedFiles = await Task.detached(priority: .utility) {
            Self.findOrphanedExternalFiles(validRefs: validRefs, externalStoragePath: contentPath)
        }.value
        guard !orphanedFiles.isEmpty else { return }

        // 3. Delete orphaned files with bounded concurrency (avoid I/O storms).
        let filesToDelete = orphanedFiles
        await Task.detached(priority: .utility) {
            await Self.deleteFilesBounded(
                filesToDelete,
                maxConcurrent: Self.maxConcurrentFileDeletions,
                logContext: "orphanCleanup"
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

    /// v0.14: 深度优化 - 消除子查询 COUNT，使用单次查询 + 事务批量删除
    /// 原理：先计算当前非 pin 数量，再用 OFFSET 直接定位要删除的记录
    /// 收益：消除 O(n) 子查询，50k 数据下节省 ~200ms
    private func cleanupByCount(target: Int) async throws {
        let plan = try await repository.planCleanupByCount(target: target)
        guard !plan.ids.isEmpty else { return }

        if !plan.storageRefs.isEmpty {
            let fileURLs = plan.storageRefs.map { URL(fileURLWithPath: $0) }
            await Task.detached(priority: .utility) {
                await Self.deleteFilesBounded(
                    fileURLs,
                    maxConcurrent: Self.maxConcurrentFileDeletions,
                    logContext: "cleanupByCount"
                )
            }.value
        }

        try await repository.deleteItemsBatchInTransaction(ids: plan.ids)
    }

    /// v0.19: 修复 - 同时删除外部存储文件，避免孤立文件累积
    private func cleanupByAge(maxDays: Int) async throws {
        let cutoff = Date().addingTimeInterval(-Double(maxDays * 24 * 3600))
        let plan = try await repository.planCleanupByAge(cutoff: cutoff)
        guard !plan.ids.isEmpty else { return }

        if !plan.storageRefs.isEmpty {
            let fileURLs = plan.storageRefs.map { URL(fileURLWithPath: $0) }
            await Task.detached(priority: .utility) {
                await Self.deleteFilesBounded(
                    fileURLs,
                    maxConcurrent: Self.maxConcurrentFileDeletions,
                    logContext: "cleanupByAge"
                )
            }.value
        }

        try await repository.deleteItemsBatchInTransaction(ids: plan.ids)
    }

    /// v0.14: 深度优化 - 消除循环迭代，单次查询 + 事务批量删除
    /// 原理：一次性获取所有待删除项目，累加 size 直到达到目标，单事务删除
    /// 收益：消除多次迭代的 SQL 开销，9000 条删除从 ~4500ms 降到 ~200ms
    private func cleanupBySize(targetBytes: Int) async throws {
        let plan = try await repository.planCleanupByTotalSize(targetBytes: targetBytes)
        guard !plan.ids.isEmpty else { return }

        if !plan.storageRefs.isEmpty {
            let fileURLs = plan.storageRefs.map { URL(fileURLWithPath: $0) }
            await Task.detached(priority: .utility) {
                await Self.deleteFilesBounded(
                    fileURLs,
                    maxConcurrent: Self.maxConcurrentFileDeletions,
                    logContext: "cleanupBySize"
                )
            }.value
        }

        try await repository.deleteItemsBatchInTransaction(ids: plan.ids)
    }

    /// v0.13: 批量删除多个项目（单条 SQL，单事务，避免 N+1 查询）
    /// v0.14: 深度优化 - 消除循环迭代，单次查询 + 事务批量删除
    /// 原理：一次性获取所有外部存储项目，累加 size 直到达到目标，单事务删除
    /// 收益：消除多次迭代的 SQL 和文件系统开销
    private func cleanupExternalStorage(targetBytes: Int) async throws {
        // 使缓存失效，确保获取最新大小
        invalidateExternalSizeCache()
        let currentSize = try await getExternalStorageSize()
        if currentSize <= targetBytes { return }

        let excessBytes = currentSize - targetBytes
        let plan = try await repository.planCleanupExternalStorage(excessBytes: excessBytes)
        guard !plan.ids.isEmpty else { return }

        let fileURLs = plan.storageRefs.map { URL(fileURLWithPath: $0) }
        await Task.detached(priority: .utility) {
            await Self.deleteFilesBounded(
                fileURLs,
                maxConcurrent: Self.maxConcurrentFileDeletions,
                logContext: "cleanupExternalStorage"
            )
        }.value
        try await repository.deleteItemsBatchInTransaction(ids: plan.ids)

        // 清理完成后使缓存失效
        invalidateExternalSizeCache()
    }

    nonisolated static func deleteFilesBounded(
        _ fileURLs: [URL],
        maxConcurrent: Int,
        logContext: StaticString
    ) async {
        guard !fileURLs.isEmpty else { return }

        let unique = Array(Set(fileURLs.map(\.path))).map { URL(fileURLWithPath: $0) }
        let remover: FileRemover = {
            #if DEBUG
            if let hook = Self.fileRemoverForTesting { return hook }
            #endif
            return { url in try FileManager.default.removeItem(at: url) }
        }()

        await forEachConcurrent(unique, maxConcurrent: maxConcurrent) { fileURL in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

            do {
                try remover(fileURL)
            } catch let error as NSError {
                // Ignore "file not found" (may be deleted concurrently).
                if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    return
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

    nonisolated static func forEachConcurrent<T: Sendable>(
        _ items: [T],
        maxConcurrent: Int,
        operation: @escaping @Sendable (T) async -> Void
    ) async {
        let limit = max(1, maxConcurrent)
        guard !items.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            let initial = min(limit, items.count)
            for _ in 0..<initial {
                guard let item = iterator.next() else { break }
                group.addTask {
                    await operation(item)
                }
            }

            while await group.next() != nil {
                guard let item = iterator.next() else { continue }
                group.addTask {
                    await operation(item)
                }
            }
        }
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
            try? FileManager.default.removeItem(at: sourceURL)
        }
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

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: ref, isDirectory: &isDirectory)
        if exists {
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

    /// 获取原图数据（用于预览）
    /// v0.22: 修复图片数据丢失问题 - 当 rawData 为 nil 时从数据库重新加载
    /// 这是因为搜索层缓存/索引中 rawData 为 nil（v0.19 内存优化）
    func getOriginalImageData(for item: StoredItem) async -> Data? {
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

    /// 清空缩略图缓存（设置变更时调用）
    func clearThumbnailCache() {
        let path = thumbnailCachePath
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            try? fileManager.removeItem(atPath: path)
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
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
