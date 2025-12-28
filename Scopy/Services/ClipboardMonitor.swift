import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ClipboardMonitor - 系统剪贴板监控服务
/// 符合 v0.md 第1节：后端只提供结构化数据和命令接口
@MainActor
public final class ClipboardMonitor {
    // MARK: - Types

    private struct SendableTimer: @unchecked Sendable {
        let timer: Timer
    }

    private final class TimerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var timer: Timer?

        func set(_ timer: Timer?) {
            lock.lock()
            defer { lock.unlock() }
            self.timer = timer
        }

        func take() -> Timer? {
            lock.lock()
            defer { lock.unlock() }
            let value = timer
            timer = nil
            return value
        }
    }

    public struct ClipboardContent: Sendable {
        public enum Payload: Sendable {
            case none
            case data(Data)
            case file(URL)
        }

        public let type: ClipboardItemType
        public let plainText: String
        public let payload: Payload
        public let note: String?
        public let appBundleID: String?
        public let contentHash: String
        public let sizeBytes: Int
        public let fileSizeBytes: Int?

        public init(
            type: ClipboardItemType,
            plainText: String,
            payload: Payload,
            note: String? = nil,
            appBundleID: String?,
            contentHash: String,
            sizeBytes: Int,
            fileSizeBytes: Int? = nil
        ) {
            self.type = type
            self.plainText = plainText
            self.payload = payload
            self.note = note
            self.appBundleID = appBundleID
            self.contentHash = contentHash
            self.sizeBytes = sizeBytes
            self.fileSizeBytes = fileSizeBytes
        }

        public var rawData: Data? {
            guard case .data(let data) = payload else { return nil }
            return data
        }

        public var ingestFileURL: URL? {
            guard case .file(let url) = payload else { return nil }
            return url
        }

        public var isEmpty: Bool {
            switch payload {
            case .none:
                return plainText.isEmpty
            case .data(let data):
                return plainText.isEmpty && data.isEmpty
            case .file:
                return false
            }
        }
    }

    /// 原始剪贴板数据（在主线程提取，但哈希计算延迟到后台）
    private struct RawClipboardData: Sendable {
        let type: ClipboardItemType
        let plainText: String
        let rawData: Data?
        let appBundleID: String?
        let sizeBytes: Int
        let fileSizeBytes: Int?
        let precomputedHash: String?  // 图片等内容的预计算轻量指纹
        let imageDataWasTIFF: Bool

        init(
            type: ClipboardItemType,
            plainText: String,
            rawData: Data?,
            appBundleID: String?,
            sizeBytes: Int,
            fileSizeBytes: Int? = nil,
            precomputedHash: String? = nil,
            imageDataWasTIFF: Bool = false
        ) {
            self.type = type
            self.plainText = plainText
            self.rawData = rawData
            self.appBundleID = appBundleID
            self.sizeBytes = sizeBytes
            self.fileSizeBytes = fileSizeBytes
            self.precomputedHash = precomputedHash
            self.imageDataWasTIFF = imageDataWasTIFF
        }
    }

    // MARK: - Properties

    private let pasteboard: NSPasteboard
    nonisolated private let timerBox: TimerBox
    private var lastChangeCount: Int = 0
    private var isMonitoring = false
    private var monitoringSessionID: UInt64 = 0
    private var isCheckingClipboard = false

    private var pendingLargeContent: [RawClipboardData] = []
    private var activeIngestTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentTasks = ScopyThresholds.ingestMaxConcurrentTasks
    private let maxPendingItems = ScopyThresholds.ingestMaxPendingItems
    private let queueLock = NSLock()

    private let contentQueue: AsyncBoundedQueue<ClipboardContent>
    public let contentStream: AsyncStream<ClipboardContent>

    private let ingestSpoolDirectory: URL

    // Configuration
    public private(set) var pollingInterval: TimeInterval = 0.5 // 500ms default
    public private(set) var ignoredApps: Set<String> = []

    // MARK: - Initialization

    public init(
        pasteboard: NSPasteboard = .general,
        pollingInterval: TimeInterval? = nil
    ) {
        self.pasteboard = pasteboard
        self.timerBox = TimerBox()
        if let pollingInterval {
            self.pollingInterval = max(0.1, min(5.0, pollingInterval))
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? {
            ScopyLog.monitor.warning("Failed to resolve caches directory; falling back to temporary directory")
            return FileManager.default.temporaryDirectory
        }()
        let scopyCaches = caches.appendingPathComponent("Scopy", isDirectory: true)
        let ingestDir = scopyCaches.appendingPathComponent("ingest", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: ingestDir, withIntermediateDirectories: true)
        } catch {
            ScopyLog.monitor.warning("Failed to create ingest spool directory: \(error.localizedDescription, privacy: .private)")
        }
        self.ingestSpoolDirectory = ingestDir

        let queue = AsyncBoundedQueue<ClipboardContent>(capacity: ScopyThresholds.monitorContentStreamMaxBufferedItems)
        self.contentQueue = queue
        self.contentStream = AsyncStream(unfolding: { await queue.dequeue() })
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        Task { [contentQueue] in
            await contentQueue.finish()
        }

        // Ensure the RunLoop timer is invalidated even if `stopMonitoring()` was not called.
        if let timer = timerBox.take() {
            let sendableTimer = SendableTimer(timer: timer)
            DispatchQueue.main.async {
                sendableTimer.timer.invalidate()
            }
        }

        // Cancel all ingest tasks and drop pending items.
        // 注意: deinit 不在 @MainActor 上下文中，使用 lock/defer unlock 模式
        queueLock.lock()
        defer { queueLock.unlock() }
        activeIngestTasks.values.forEach { $0.cancel() }
        activeIngestTasks.removeAll()
        pendingLargeContent.removeAll()
        isMonitoring = false
    }

    // MARK: - Public API

    /// v0.10.4: 移除重复的 RunLoop.add 调用
    public func startMonitoring() {
        // v0.10.7: 确保在主线程调用，否则 Timer 不会触发
        assert(Thread.isMainThread, "startMonitoring must be called on main thread")

        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringSessionID &+= 1
        lastChangeCount = pasteboard.changeCount

        // Important: schedule on `.common` modes so UI/menu tracking doesn't pause sampling.
        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkClipboard()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timerBox.set(timer)
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitoringSessionID &+= 1

        if let timer = timerBox.take() {
            timer.invalidate()
        }
        // Cancel all ingest tasks and drop pending items.
        // 注意: 此方法在 @MainActor 上下文中执行，使用 lock/defer unlock 模式
        queueLock.lock()
        defer { queueLock.unlock() }
        activeIngestTasks.values.forEach { $0.cancel() }
        activeIngestTasks.removeAll()
        pendingLargeContent.removeAll()
    }

    public func setPollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(0.1, min(5.0, interval)) // Clamp between 100ms and 5s
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    public func setIgnoredApps(_ apps: Set<String>) {
        ignoredApps = apps
    }

    /// Manually read current clipboard content
    public func readCurrentClipboard() -> ClipboardContent? {
        return extractContent(from: pasteboard)
    }

    /// Copy content to system clipboard
    public func copyToClipboard(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Update change count to avoid triggering our own copy as new item
        lastChangeCount = pasteboard.changeCount
    }

    public func copyToClipboard(data: Data, type: NSPasteboard.PasteboardType) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        lastChangeCount = pasteboard.changeCount
    }

    public func copyToClipboard(text: String, data: Data, type: NSPasteboard.PasteboardType) {
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(data, forType: type)
        pasteboard.writeObjects([item])

        lastChangeCount = pasteboard.changeCount
    }

    /// Copy file URLs to system clipboard
    /// 将文件 URL 复制到系统剪贴板，支持 Finder 粘贴
    public func copyToClipboard(fileURLs: [URL]) {
        pasteboard.clearContents()

        // 方法1: 使用 NSURL 的 NSPasteboardWriting 协议
        pasteboard.writeObjects(fileURLs as [NSURL])

        // 方法2: 同时设置 NSFilenamesPboardType，确保 Finder 兼容
        // 这是旧的 API，但 Finder 仍然依赖它
        let paths = fileURLs.map { $0.path }
        pasteboard.setPropertyList(paths, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - File URL Serialization

    /// 序列化文件 URL 数组为 Data
    /// 使用文件路径而非 absoluteString，确保反序列化时能正确还原为文件 URL
    nonisolated static func serializeFileURLs(_ urls: [URL]) -> Data? {
        do {
            // 使用 .path 而非 .absoluteString，避免 file:// 前缀问题
            let paths = urls.map { $0.path }
            return try JSONEncoder().encode(paths)
        } catch {
            ScopyLog.monitor.error("Failed to serialize file URLs: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// 从 Data 反序列化文件 URL 数组
    /// 使用 URL(fileURLWithPath:) 确保正确创建文件 URL
    nonisolated static func deserializeFileURLs(_ data: Data) -> [URL]? {
        do {
            let paths = try JSONDecoder().decode([String].self, from: data)
            return paths.map { URL(fileURLWithPath: $0) }
        } catch {
            ScopyLog.monitor.error("Failed to deserialize file URLs: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    nonisolated private static func fileSizeBytesBestEffort(_ urls: [URL]) -> Int? {
        var total = 0
        var didRead = false

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
                didRead = true
            }
        }

        return didRead ? total : nil
    }

    // MARK: - Private Methods

    private func checkClipboard() async {
        guard isMonitoring else { return }
        guard !isCheckingClipboard else { return }
        isCheckingClipboard = true
        defer { isCheckingClipboard = false }

        let currentChangeCount = pasteboard.changeCount
        let previousChangeCount = lastChangeCount

        guard currentChangeCount != previousChangeCount else { return }
        let delta = currentChangeCount - previousChangeCount
        if delta > 1 {
            ScopyLog.monitor.debug("Pasteboard changeCount jumped by \(delta) (prev=\(previousChangeCount), current=\(currentChangeCount))")
        }
        lastChangeCount = currentChangeCount

        // 快速提取原始数据（在主线程）
        guard let rawData = extractRawData(from: pasteboard) else { return }

        // Check if we should ignore this app
        if let appID = rawData.appBundleID, ignoredApps.contains(appID) {
            return
        }

        // Skip empty content
        guard !rawData.plainText.isEmpty || (rawData.rawData != nil && !rawData.rawData!.isEmpty) else {
            return
        }

        // v0.10.4: 根据内容类型和大小决定处理方式
        // 1. 图片一律走后台 SHA256，避免轻指纹误判
        // 2. 所有大内容（包括非图片）都异步处理，避免主线程阻塞
        // 3. 只有小内容在主线程同步处理
        if rawData.type == .image || rawData.sizeBytes >= ScopyThresholds.ingestHashOffloadBytes {
            // 图片或大内容：异步处理
            processLargeContentAsync(rawData)
            return
        }

        // 小内容（非图片）：同步处理
        let hash = computeHash(rawData)
        let content = ClipboardContent(
            type: rawData.type,
            plainText: rawData.plainText,
            payload: rawData.rawData.map(ClipboardContent.Payload.data) ?? .none,
            appBundleID: rawData.appBundleID,
            contentHash: hash,
            sizeBytes: rawData.sizeBytes,
            fileSizeBytes: rawData.fileSizeBytes
        )
        await contentQueue.enqueue(content)
    }

    /// 异步处理大内容（在后台线程计算哈希）
    private func processLargeContentAsync(_ rawData: RawClipboardData) {
        queueLock.lock()
        defer { queueLock.unlock() }

        // Best-effort cleanup: remove cancelled tasks.
        if !activeIngestTasks.isEmpty {
            activeIngestTasks = Dictionary(uniqueKeysWithValues: activeIngestTasks.filter { !$0.value.isCancelled })
        }

        if pendingLargeContent.count >= maxPendingItems {
            ScopyLog.monitor.error(
                "Ingest backlog full (\(self.maxPendingItems, privacy: .public)), dropping oldest pending item"
            )
            pendingLargeContent.removeFirst()
        }

        pendingLargeContent.append(rawData)
        startNextIngestTasksIfNeeded()
    }

    private func startNextIngestTasksIfNeeded() {
        while activeIngestTasks.count < maxConcurrentTasks, !pendingLargeContent.isEmpty {
            let next = pendingLargeContent.removeFirst()

            let taskID = UUID()
            let ingestDirectory = ingestSpoolDirectory
            let spoolThresholdBytes = ScopyThresholds.ingestSpoolBytes
            let sessionID = monitoringSessionID
            let contentQueue = contentQueue

            let task = Task.detached(priority: .userInitiated) { [weak self, taskID, ingestDirectory, sessionID, contentQueue] in
                defer {
                    Task { @MainActor [weak self] in
                        self?.finishIngestTask(id: taskID)
                    }
                }

                guard let self else { return }

                guard !Task.isCancelled else { return }

                var payloadData = next.rawData
                var plainText = next.plainText
                var sizeBytes = next.sizeBytes

                if next.type == .image, let imageData = next.rawData {
                    if next.imageDataWasTIFF, let pngData = Self.convertTIFFToPNG(imageData) {
                        payloadData = pngData
                    } else {
                        payloadData = imageData
                    }
                    sizeBytes = payloadData?.count ?? imageData.count
                    plainText = "[Image: \(Self.formatBytes(sizeBytes))]"
                }

                let hash: String
                if let precomputed = next.precomputedHash {
                    hash = precomputed
                } else if let payloadData {
                    hash = Self.computeHashStatic(payloadData)
                } else {
                    hash = Self.computeHashStatic(Data(plainText.utf8))
                }

                let payload = Self.buildPayload(
                    type: next.type,
                    data: payloadData,
                    sizeBytes: sizeBytes,
                    ingestDirectory: ingestDirectory,
                    spoolThresholdBytes: spoolThresholdBytes
                )

                if Task.isCancelled {
                    Self.cleanupPayloadIfNeeded(payload)
                    return
                }

                let resolvedPlainText = plainText
                let resolvedSizeBytes = sizeBytes

                let shouldEmit = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    guard !Task.isCancelled else { return false }
                    guard self.isMonitoring else { return false }
                    guard self.monitoringSessionID == sessionID else { return false }
                    return true
                }

                guard shouldEmit else {
                    Self.cleanupPayloadIfNeeded(payload)
                    return
                }

                let content = ClipboardContent(
                    type: next.type,
                    plainText: resolvedPlainText,
                    payload: payload,
                    appBundleID: next.appBundleID,
                    contentHash: hash,
                    sizeBytes: resolvedSizeBytes,
                    fileSizeBytes: next.fileSizeBytes
                )

                await contentQueue.enqueue(content)
            }

            activeIngestTasks[taskID] = task
        }
    }

    private func finishIngestTask(id: UUID) {
        queueLock.lock()
        defer { queueLock.unlock() }

        activeIngestTasks.removeValue(forKey: id)
        startNextIngestTasksIfNeeded()
    }

    nonisolated private static func buildPayload(
        type: ClipboardItemType,
        data: Data?,
        sizeBytes: Int,
        ingestDirectory: URL,
        spoolThresholdBytes: Int
    ) -> ClipboardContent.Payload {
        guard let data else { return .none }

        guard sizeBytes >= spoolThresholdBytes else {
            return .data(data)
        }

        let ext: String
        switch type {
        case .image: ext = "png"
        case .rtf: ext = "rtf"
        case .html: ext = "html"
        default: ext = "dat"
        }

        let fileURL = ingestDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try StorageService.writeAtomically(data, to: fileURL.path)
            return .file(fileURL)
        } catch {
            ScopyLog.monitor.warning("Failed to spool ingest payload: \(error.localizedDescription, privacy: .private)")
            return .data(data)
        }
    }

    nonisolated private static func cleanupPayloadIfNeeded(_ payload: ClipboardContent.Payload) {
        guard case .file(let url) = payload else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 快速提取原始数据（不计算哈希，避免阻塞主线程）
    /// 注意：检测顺序很重要！文件复制时剪贴板同时包含 file URL 和 plain text，
    /// 必须先检测 file URL，否则会被误识别为文本。
    private func extractRawData(from pasteboard: NSPasteboard) -> RawClipboardData? {
        let appBundleID = getFrontmostAppBundleID()

        // 检测顺序：File URLs > Image > RTF > HTML > Plain text
        // Plain text 必须放最后，因为其他类型通常也包含文本表示

        // 1. File URLs (最高优先级 - 文件复制总是带有文本表示)
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }.joined(separator: "\n")
            // 序列化文件 URL 以便后续恢复
            let urlData = Self.serializeFileURLs(fileURLs)
            let fileSizeBytes = Self.fileSizeBytesBestEffort(fileURLs)
            return RawClipboardData(
                type: .file,
                plainText: paths,
                rawData: urlData,
                appBundleID: appBundleID,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0),
                fileSizeBytes: fileSizeBytes
            )
        }

        // 2. Image (PNG, TIFF, etc.) - 优先 PNG；TIFF 转 PNG 延迟到后台（避免主线程重编码）
        // v0.19: 图片统一使用 SHA256 去重（在后台线程计算），移除无用的轻量指纹
        if let imageResult = extractImageDataForIngest(from: pasteboard) {
            let imageData = imageResult.data
            return RawClipboardData(
                type: .image,
                plainText: "[Image]",
                rawData: imageData,
                appBundleID: appBundleID,
                sizeBytes: imageData.count,
                precomputedHash: nil,
                imageDataWasTIFF: imageResult.wasTIFF
            )
        }

        // 3. RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: rtfData, type: .rtf))
            return RawClipboardData(
                type: .rtf,
                plainText: plainText,
                rawData: rtfData,
                appBundleID: appBundleID,
                sizeBytes: rtfData.count
            )
        }

        // 4. HTML
        if let htmlData = pasteboard.data(forType: .html) {
            let plainText = normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: htmlData, type: .html))
            return RawClipboardData(
                type: .html,
                plainText: plainText,
                rawData: htmlData,
                appBundleID: appBundleID,
                sizeBytes: htmlData.count
            )
        }

        // 5. Plain text (最低优先级 - 作为兜底)
        if let string = pasteboard.string(forType: .string) {
            let normalizedText = normalizeText(string)
            return RawClipboardData(
                type: .text,
                plainText: normalizedText,
                rawData: nil,
                appBundleID: appBundleID,
                sizeBytes: normalizedText.utf8.count
            )
        }

        return nil
    }

    /// 为 RawClipboardData 计算哈希（用于小内容，在主线程同步执行）
    private func computeHash(_ rawData: RawClipboardData) -> String {
        // 如果有预计算的指纹（如图片轻量指纹），直接使用
        if let precomputed = rawData.precomputedHash {
            return precomputed
        }
        // 否则计算 SHA256
        //
        // v0.md 3.2：文本去重以“标准化后的主文本”为准（去首尾空白、统一换行）。
        // - text / rtf / html：以 plainText 计算 hash，避免 RTF/HTML payload 中的可变 metadata 造成“看起来一样但 hash 不同”。
        // - image：以二进制数据计算 hash。
        // - file：以路径文本计算 hash（序列化 URL 数据可能含可变字段）。
        switch rawData.type {
        case .text, .rtf, .html:
            if !rawData.plainText.isEmpty {
                return computeHash(rawData.plainText)
            }
            if let data = rawData.rawData {
                return computeHash(data)
            }
            return computeHash(rawData.plainText)
        case .file:
            return computeHash(rawData.plainText)
        case .image:
            if let data = rawData.rawData {
                return computeHash(data)
            }
            return computeHash(rawData.plainText)
        case .other:
            if let data = rawData.rawData {
                return computeHash(data)
            }
            return computeHash(rawData.plainText)
        }
    }

    /// 提取剪贴板内容（包含哈希计算）
    /// 注意：检测顺序与 extractRawData 保持一致
    private func extractContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        let appBundleID = getFrontmostAppBundleID()

        // 检测顺序：File URLs > Image > RTF > HTML > Plain text
        // Plain text 必须放最后，因为其他类型通常也包含文本表示

        // 1. File URLs (最高优先级)
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }.joined(separator: "\n")
            let hash = computeHash(paths)
            // 序列化文件 URL 以便后续恢复
            let urlData = Self.serializeFileURLs(fileURLs)
            let fileSizeBytes = Self.fileSizeBytesBestEffort(fileURLs)
            return ClipboardContent(
                type: .file,
                plainText: paths,
                payload: urlData.map(ClipboardContent.Payload.data) ?? .none,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0),
                fileSizeBytes: fileSizeBytes
            )
        }

        // 2. Image (PNG, TIFF, etc.) - 优先 PNG，TIFF 转为 PNG 避免存储膨胀
        if let imageResult = extractOptimalImageData(from: pasteboard) {
            let imageData = imageResult.data
            let hash = computeHash(imageData)
            return ClipboardContent(
                type: .image,
                plainText: "[Image: \(Self.formatBytes(imageData.count))]",
                payload: .data(imageData),
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: imageData.count
            )
        }

        // 3. RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: rtfData, type: .rtf))
            // Dedup by normalized main text (v0.md 3.2). RTF payload may vary across copies even when the text is identical.
            let hash = plainText.isEmpty ? computeHash(rtfData) : computeHash(plainText)
            return ClipboardContent(
                type: .rtf,
                plainText: plainText,
                payload: .data(rtfData),
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: rtfData.count
            )
        }

        // 4. HTML
        if let htmlData = pasteboard.data(forType: .html) {
            let plainText = normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: htmlData, type: .html))
            // Dedup by normalized main text (v0.md 3.2). HTML payload may include volatile metadata.
            let hash = plainText.isEmpty ? computeHash(htmlData) : computeHash(plainText)
            return ClipboardContent(
                type: .html,
                plainText: plainText,
                payload: .data(htmlData),
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: htmlData.count
            )
        }

        // 5. Plain text (最低优先级 - 作为兜底)
        if let string = pasteboard.string(forType: .string) {
            let normalizedText = normalizeText(string)
            let hash = computeHash(normalizedText)
            return ClipboardContent(
                type: .text,
                plainText: normalizedText,
                payload: .none,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: normalizedText.utf8.count
            )
        }

        return nil
    }

    // MARK: - Helper Methods

    private func extractPreferredPlainText(from pasteboard: NSPasteboard, richTextData: Data, type: ClipboardItemType) -> String {
        // For rich types, prefer the pasteboard-provided `.string` when it's a faithful plain-text representation of
        // the rich payload. Some apps provide `.string` that is already a lossy transformation (e.g. rich -> Markdown),
        // which can corrupt TeX-heavy content; in those cases, fall back to extracting plain text from the rich payload.
        let extracted: String?
        switch type {
        case .rtf:
            extracted = extractPlainTextFromRTF(richTextData)
        case .html:
            extracted = extractPlainTextFromHTML(richTextData)
        default:
            extracted = nil
        }

        let candidate = pasteboard.string(forType: .string) ?? ""
        if candidate.isEmpty {
            return extracted ?? ""
        }

        guard let extracted, !extracted.isEmpty else {
            return candidate
        }

        if normalizeText(candidate) == normalizeText(extracted) {
            return candidate
        }

        // If the extracted text is TeX-heavy and the pasteboard `.string` differs materially from it, prefer the
        // extracted version to avoid storing a transformed/Markdown-converted representation.
        if containsTeXCommands(extracted) {
            return extracted
        }

        return candidate
    }

    private func containsTeXCommands(_ text: String) -> Bool {
        var sawBackslash = false
        for ch in text {
            if sawBackslash {
                if ch.isLetter { return true }
                sawBackslash = false
                continue
            }
            if ch == "\\" {
                sawBackslash = true
            }
        }
        return false
    }

    private func getFrontmostAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Normalize text for consistent hashing (v0.md 3.2: 去首尾空白、统一换行)
    private func normalizeText(_ text: String) -> String {
        text
            // Normalize common Unicode line separators to '\n' for stable hashing (still "统一换行").
            .replacingOccurrences(of: "\u{2028}", with: "\n") // LINE SEPARATOR
            .replacingOccurrences(of: "\u{2029}", with: "\n") // PARAGRAPH SEPARATOR
            .replacingOccurrences(of: "\u{0085}", with: "\n") // NEXT LINE
            // Normalize NBSP/BOM that commonly appear in PDF/web copies.
            .replacingOccurrences(of: "\u{00A0}", with: " ")  // NO-BREAK SPACE
            .replacingOccurrences(of: "\u{FEFF}", with: "")   // BOM / ZERO WIDTH NO-BREAK SPACE
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Compute content hash for deduplication (v0.md 3.2)
    private func computeHash(_ text: String) -> String {
        computeHash(Data(text.utf8))
    }

    private func computeHash(_ data: Data) -> String {
        Self.computeHashStatic(data)
    }

    /// 静态哈希计算方法（可在任意线程调用）
    public nonisolated static func computeHashStatic(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Image Fingerprint (轻量级图片指纹)

    /// 计算图片轻量指纹：分辨率 + 四角4x4像素块
    /// 格式: "img:{width}x{height}:{cornerPixelsHash}"
    nonisolated static func computeImageFingerprint(_ imageData: Data) -> String? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        // 获取四角像素指纹
        let cornerHash = extractCornerPixelsHash(from: cgImage, width: width, height: height)

        return "img:\(width)x\(height):\(cornerHash)"
    }

    /// v0.19: 使用缩略图计算哈希，大幅减少内存占用
    /// 将图片缩放到 32x32 后计算全图哈希，而不是在原图上提取四角
    /// 4K 图片：原方案 33MB -> 新方案 4KB (减少 99.99%)
    nonisolated private static let thumbnailSize = 32

    nonisolated private static func extractCornerPixelsHash(from cgImage: CGImage, width: Int, height: Int) -> String {
        return autoreleasepool {
            let thumbSize = thumbnailSize
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerPixel = 4
            let bytesPerRow = bytesPerPixel * thumbSize
            let bitsPerComponent = 8

            // 创建 32x32 的缩略图上下文（仅 4KB 内存）
            guard let context = CGContext(
                data: nil,
                width: thumbSize,
                height: thumbSize,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return "\(width)\(height)"
            }

            // 将原图绘制到缩略图上下文（自动缩放）
            context.interpolationQuality = .low  // 快速缩放
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))

            guard let data = context.data else {
                return "\(width)\(height)"
            }

            // 读取缩略图全部像素
            let buffer = data.bindMemory(to: UInt8.self, capacity: thumbSize * thumbSize * bytesPerPixel)
            var pixelData: [UInt8] = []
            pixelData.reserveCapacity(thumbSize * thumbSize * 3)

            for i in 0..<(thumbSize * thumbSize) {
                let offset = i * bytesPerPixel
                pixelData.append(buffer[offset])     // R
                pixelData.append(buffer[offset + 1]) // G
                pixelData.append(buffer[offset + 2]) // B
            }

            return compressPixelData(pixelData)
        }
    }

    /// 压缩像素数据为短哈希（约32字符）
    nonisolated private static func compressPixelData(_ pixels: [UInt8]) -> String {
        // 简单的 XOR 折叠 + 十六进制编码
        var hash: [UInt8] = [UInt8](repeating: 0, count: 16)
        for (i, byte) in pixels.enumerated() {
            hash[i % 16] ^= byte
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func extractPlainTextFromRTF(_ data: Data) -> String? {
        guard let attributedString = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }
        return attributedString.string
    }

    private func extractPlainTextFromHTML(_ data: Data) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html
        ]
        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return attributedString.string
    }

    nonisolated private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    // MARK: - TIFF to PNG Conversion

    /// 将 TIFF 数据转换为 PNG 格式（避免存储膨胀）
    /// macOS 剪贴板对截图返回 TIFF（未压缩），可能比原始 PNG 大 35 倍
    nonisolated static func convertTIFFToPNG(_ tiffData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
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

        CGImageDestinationAddImageFromSource(destination, imageSource, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 从剪贴板提取图片数据（用于 ingest），优先 PNG；TIFF 转 PNG 在后台执行
    private func extractImageDataForIngest(from pasteboard: NSPasteboard) -> (data: Data, wasTIFF: Bool)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, false)
        }

        if let tiffData = pasteboard.data(forType: .tiff) {
            return (tiffData, true)
        }

        return nil
    }

    /// 从剪贴板提取图片数据，优先 PNG，如果只有 TIFF 则转换为 PNG
    private func extractOptimalImageData(from pasteboard: NSPasteboard) -> (data: Data, wasTIFF: Bool)? {
        // 优先检查 PNG（已压缩格式）
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, false)
        }

        // 只有 TIFF 时，转换为 PNG 以节省存储
        if let tiffData = pasteboard.data(forType: .tiff) {
            if let pngData = Self.convertTIFFToPNG(tiffData) {
                return (pngData, true)
            }
            // 转换失败时保留 TIFF
            return (tiffData, true)
        }

        return nil
    }
}
