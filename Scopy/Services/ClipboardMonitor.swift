import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// ClipboardMonitor - 系统剪贴板监控服务
/// 符合 v0.md 第1节：后端只提供结构化数据和命令接口
@MainActor
final class ClipboardMonitor {
    // MARK: - Types

    struct ClipboardContent: Sendable {
        let type: ClipboardItemType
        let plainText: String
        let rawData: Data?
        let appBundleID: String?
        let contentHash: String
        let sizeBytes: Int

        var isEmpty: Bool {
            plainText.isEmpty && (rawData?.isEmpty ?? true)
        }
    }

    /// 原始剪贴板数据（在主线程提取，但哈希计算延迟到后台）
    private struct RawClipboardData: Sendable {
        let type: ClipboardItemType
        let plainText: String
        let rawData: Data?
        let appBundleID: String?
        let sizeBytes: Int
        let precomputedHash: String?  // 图片等内容的预计算轻量指纹

        init(type: ClipboardItemType, plainText: String, rawData: Data?, appBundleID: String?, sizeBytes: Int, precomputedHash: String? = nil) {
            self.type = type
            self.plainText = plainText
            self.rawData = rawData
            self.appBundleID = appBundleID
            self.sizeBytes = sizeBytes
            self.precomputedHash = precomputedHash
        }
    }

    // MARK: - Properties

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var isMonitoring = false
    private var isContentStreamFinished = false

    /// v0.22: 保护 isContentStreamFinished 的锁，防止 stopMonitoring() 和 yield() 之间的竞态
    private let contentStreamLock = NSLock()

    /// v0.10.8: 使用任务队列替代单任务，支持快速连续复制大文件
    private var processingQueue: [Task<Void, Never>] = []
    /// v0.17: 任务 ID 映射，用于在任务完成后清理
    private var taskIDMap: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentTasks = 3
    private let queueLock = NSLock()

    private let eventContinuation: AsyncStream<ClipboardContent>.Continuation
    let contentStream: AsyncStream<ClipboardContent>

    /// 后台处理队列（用于大文件的哈希计算）
    private let backgroundQueue = DispatchQueue(label: "com.scopy.clipboard.hash", qos: .userInitiated)

    // Configuration
    private(set) var pollingInterval: TimeInterval = 0.5 // 500ms default
    private(set) var ignoredApps: Set<String> = []

    /// 大内容阈值：超过此大小的内容在后台线程处理哈希
    private static let largeContentThreshold = 50 * 1024 // 50 KB

    // MARK: - Initialization

    init() {
        var continuation: AsyncStream<ClipboardContent>.Continuation!
        self.contentStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    deinit {
        // Direct cleanup in deinit (synchronous)
        // v0.22.1: 使用锁保护 isContentStreamFinished，与 checkClipboard() 中的锁保持一致
        contentStreamLock.lock()
        isContentStreamFinished = true
        contentStreamLock.unlock()

        timer?.invalidate()
        timer = nil
        // v0.10.8: 取消所有处理任务
        // 注意: deinit 不在 @MainActor 上下文中，使用 lock/defer unlock 模式
        queueLock.lock()
        defer { queueLock.unlock() }
        processingQueue.forEach { $0.cancel() }
        processingQueue.removeAll()
        taskIDMap.removeAll()  // v0.17: 清理任务 ID 映射
        isMonitoring = false
    }

    // MARK: - Public API

    /// v0.10.4: 移除重复的 RunLoop.add 调用
    func startMonitoring() {
        // v0.10.7: 确保在主线程调用，否则 Timer 不会触发
        assert(Thread.isMainThread, "startMonitoring must be called on main thread")

        guard !isMonitoring else { return }
        isMonitoring = true
        lastChangeCount = NSPasteboard.general.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkClipboard()
            }
        }
        // Timer.scheduledTimer 已自动添加到 RunLoop.current，无需再次添加
    }

    /// v0.22: 使用锁保护 isContentStreamFinished，防止与 yield() 竞态
    func stopMonitoring() {
        // 使用锁保护状态设置，确保与 yield 操作互斥
        let shouldStop = contentStreamLock.withLock { () -> Bool in
            guard !isContentStreamFinished else { return false }
            isContentStreamFinished = true
            return true
        }
        guard shouldStop else { return }

        timer?.invalidate()
        timer = nil
        // v0.10.8: 取消所有处理任务
        // 注意: 此方法在 @MainActor 上下文中执行，使用 lock/defer unlock 模式
        queueLock.lock()
        defer { queueLock.unlock() }
        processingQueue.forEach { $0.cancel() }
        processingQueue.removeAll()
        taskIDMap.removeAll()  // v0.17: 清理任务 ID 映射
        isMonitoring = false
    }

    func setPollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(0.1, min(5.0, interval)) // Clamp between 100ms and 5s
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    func setIgnoredApps(_ apps: Set<String>) {
        ignoredApps = apps
    }

    /// Manually read current clipboard content
    func readCurrentClipboard() -> ClipboardContent? {
        let pasteboard = NSPasteboard.general
        return extractContent(from: pasteboard)
    }

    /// Copy content to system clipboard
    func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Update change count to avoid triggering our own copy as new item
        lastChangeCount = pasteboard.changeCount
    }

    func copyToClipboard(data: Data, type: NSPasteboard.PasteboardType) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        lastChangeCount = pasteboard.changeCount
    }

    /// Copy file URLs to system clipboard
    /// 将文件 URL 复制到系统剪贴板，支持 Finder 粘贴
    func copyToClipboard(fileURLs: [URL]) {
        let pasteboard = NSPasteboard.general
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
            print("Failed to serialize file URLs: \(error)")
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
            print("Failed to deserialize file URLs: \(error)")
            return nil
        }
    }

    // MARK: - Private Methods

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        guard currentChangeCount != lastChangeCount else { return }
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
        if rawData.type == .image || rawData.sizeBytes >= Self.largeContentThreshold {
            // 图片或大内容：异步处理
            processLargeContentAsync(rawData)
            return
        }

        // 小内容（非图片）：同步处理
        let hash = computeHash(rawData)
        let content = ClipboardContent(
            type: rawData.type,
            plainText: rawData.plainText,
            rawData: rawData.rawData,
            appBundleID: rawData.appBundleID,
            contentHash: hash,
            sizeBytes: rawData.sizeBytes
        )
        // v0.22: 使用锁保护 yield 操作，防止与 stopMonitoring() 竞态
        contentStreamLock.withLock {
            guard !isContentStreamFinished else { return }
            eventContinuation.yield(content)
        }
    }

    /// 异步处理大内容（在后台线程计算哈希）
    /// v0.10.8: 使用任务队列替代单任务，支持快速连续复制大文件
    /// v0.17: 修复任务完成后不自动清理的内存泄漏问题
    /// 注意: 此方法在 @MainActor 上下文中执行，使用 lock/defer unlock 模式
    /// 因为 withLock 闭包不继承 @MainActor 隔离
    private func processLargeContentAsync(_ rawData: RawClipboardData) {
        queueLock.lock()
        defer { queueLock.unlock() }

        // 清理已取消的任务
        processingQueue.removeAll { $0.isCancelled }

        // 如果队列满，取消最旧的任务
        // v0.22: 添加日志，帮助诊断快速复制时的任务丢弃情况
        while processingQueue.count >= maxConcurrentTasks {
            print("⚠️ ClipboardMonitor: Task queue full (\(maxConcurrentTasks)), dropping oldest task")
            processingQueue.first?.cancel()
            processingQueue.removeFirst()
        }

        // 使用 UUID 标识任务，以便在完成后清理
        let taskID = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self, taskID] in
            // 确保任务完成后从队列中移除
            defer {
                Task { @MainActor [weak self] in
                    self?.removeCompletedTask(id: taskID)
                }
            }

            guard let self = self else { return }

            // 在后台线程计算哈希
            let hash = await self.computeHashInBackground(rawData)

            // 检查任务是否被取消
            guard !Task.isCancelled else { return }

            // 回到主线程发送事件
            // v0.10.7: 在 MainActor.run 内再次检查取消状态，防止向已关闭的流发送数据
            // v0.22: 使用锁保护 yield 操作，防止与 stopMonitoring() 竞态
            await MainActor.run {
                guard !Task.isCancelled else { return }

                let content = ClipboardContent(
                    type: rawData.type,
                    plainText: rawData.plainText,
                    rawData: rawData.rawData,
                    appBundleID: rawData.appBundleID,
                    contentHash: hash,
                    sizeBytes: rawData.sizeBytes
                )
                self.contentStreamLock.withLock {
                    guard !self.isContentStreamFinished else { return }
                    self.eventContinuation.yield(content)
                }
            }
        }
        processingQueue.append(task)
        taskIDMap[taskID] = task
    }

    /// v0.17: 从队列中移除已完成的任务
    /// v0.20: 修复内存泄漏 - 使用 UUID 而非 ObjectIdentifier 跟踪任务
    /// v0.23: 简化逻辑 - taskIDMap 是唯一数据源，processingQueue 从 taskIDMap 重建
    /// 注意: 此方法在 @MainActor 上下文中执行，使用 lock/defer unlock 模式
    private func removeCompletedTask(id: UUID) {
        queueLock.lock()
        defer { queueLock.unlock() }

        // 从 taskIDMap 移除已完成的任务
        taskIDMap.removeValue(forKey: id)

        // 重建 processingQueue：只保留 taskIDMap 中的活跃任务
        // 这确保两个数据结构始终同步
        processingQueue = Array(taskIDMap.values)
    }

    /// 在后台线程计算哈希
    /// v0.19: 统一使用 SHA256 进行去重，确保准确性
    nonisolated private func computeHashInBackground(_ rawData: RawClipboardData) async -> String {
        // 如果有预计算的哈希（非图片类型），直接使用
        if let precomputed = rawData.precomputedHash {
            return precomputed
        }

        // 所有类型（包括图片）统一使用 SHA256
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let hash: String
                if let data = rawData.rawData {
                    hash = Self.computeHashStatic(data)
                } else {
                    hash = Self.computeHashStatic(Data(rawData.plainText.utf8))
                }
                continuation.resume(returning: hash)
            }
        }
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
            return RawClipboardData(
                type: .file,
                plainText: paths,
                rawData: urlData,
                appBundleID: appBundleID,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0)
            )
        }

        // 2. Image (PNG, TIFF, etc.) - 优先 PNG，TIFF 转为 PNG 避免存储膨胀
        // v0.19: 图片统一使用 SHA256 去重（在后台线程计算），移除无用的轻量指纹
        if let imageResult = extractOptimalImageData(from: pasteboard) {
            let imageData = imageResult.data
            return RawClipboardData(
                type: .image,
                plainText: "[Image: \(formatBytes(imageData.count))]",
                rawData: imageData,
                appBundleID: appBundleID,
                sizeBytes: imageData.count,
                precomputedHash: nil  // 图片哈希在后台线程计算
            )
        }

        // 3. RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = extractPlainTextFromRTF(rtfData) ?? ""
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
            let plainText = extractPlainTextFromHTML(htmlData) ?? ""
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
        if let data = rawData.rawData {
            return computeHash(data)
        } else {
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
            return ClipboardContent(
                type: .file,
                plainText: paths,
                rawData: urlData,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0)
            )
        }

        // 2. Image (PNG, TIFF, etc.) - 优先 PNG，TIFF 转为 PNG 避免存储膨胀
        if let imageResult = extractOptimalImageData(from: pasteboard) {
            let imageData = imageResult.data
            let hash = computeHash(imageData)
            return ClipboardContent(
                type: .image,
                plainText: "[Image: \(formatBytes(imageData.count))]",
                rawData: imageData,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: imageData.count
            )
        }

        // 3. RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            let plainText = extractPlainTextFromRTF(rtfData) ?? ""
            let hash = computeHash(rtfData)
            return ClipboardContent(
                type: .rtf,
                plainText: plainText,
                rawData: rtfData,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: rtfData.count
            )
        }

        // 4. HTML
        if let htmlData = pasteboard.data(forType: .html) {
            let plainText = extractPlainTextFromHTML(htmlData) ?? ""
            let hash = computeHash(htmlData)
            return ClipboardContent(
                type: .html,
                plainText: plainText,
                rawData: htmlData,
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
                rawData: nil,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: normalizedText.utf8.count
            )
        }

        return nil
    }

    // MARK: - Helper Methods

    private func getFrontmostAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Normalize text for consistent hashing (v0.md 3.2: 去首尾空白、统一换行)
    private func normalizeText(_ text: String) -> String {
        text
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
    nonisolated static func computeHashStatic(_ data: Data) -> String {
        // Use SHA256 for content hash
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
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
    private static let thumbnailSize = 32

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
        guard let htmlString = String(data: data, encoding: .utf8),
              let attributedString = try? NSAttributedString(
                data: Data(htmlString.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else {
            return nil
        }
        return attributedString.string
    }

    private func formatBytes(_ bytes: Int) -> String {
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
        guard let imageSource = CGImageSourceCreateWithData(tiffData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
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

// MARK: - Simple SHA256 Implementation (avoid CryptoKit import issues)

private struct SHA256 {
    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var buffer: [UInt8] = []
    private var processedBytes: UInt64 = 0

    mutating func update(data: Data) {
        buffer.append(contentsOf: data)
        processedBytes += UInt64(data.count)

        while buffer.count >= 64 {
            let chunk = Array(buffer.prefix(64))
            processBlock(chunk)
            buffer.removeFirst(64)
        }
    }

    mutating func finalize() -> [UInt8] {
        var remaining = buffer
        let bitLength = processedBytes * 8

        remaining.append(0x80)
        while (remaining.count % 64) != 56 {
            remaining.append(0x00)
        }

        for i in (0..<8).reversed() {
            remaining.append(UInt8((bitLength >> (i * 8)) & 0xff))
        }

        for start in stride(from: 0, to: remaining.count, by: 64) {
            let chunk = Array(remaining[start..<start+64])
            processBlock(chunk)
        }

        var result: [UInt8] = []
        for value in h {
            result.append(UInt8((value >> 24) & 0xff))
            result.append(UInt8((value >> 16) & 0xff))
            result.append(UInt8((value >> 8) & 0xff))
            result.append(UInt8(value & 0xff))
        }
        return result
    }

    private mutating func processBlock(_ chunk: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)

        for i in 0..<16 {
            w[i] = UInt32(chunk[i*4]) << 24 |
                   UInt32(chunk[i*4+1]) << 16 |
                   UInt32(chunk[i*4+2]) << 8 |
                   UInt32(chunk[i*4+3])
        }

        for i in 16..<64 {
            let s0 = rightRotate(w[i-15], by: 7) ^ rightRotate(w[i-15], by: 18) ^ (w[i-15] >> 3)
            let s1 = rightRotate(w[i-2], by: 17) ^ rightRotate(w[i-2], by: 19) ^ (w[i-2] >> 10)
            w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
        }

        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], hh = h[7]

        for i in 0..<64 {
            let S1 = rightRotate(e, by: 6) ^ rightRotate(e, by: 11) ^ rightRotate(e, by: 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = rightRotate(a, by: 2) ^ rightRotate(a, by: 13) ^ rightRotate(a, by: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = S0 &+ maj

            hh = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }

        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    private func rightRotate(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
