import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public actor ClipboardIngestMetrics {
    public static let shared = ClipboardIngestMetrics()

    private var pendingCount = 0
    private var activeCount = 0
    private var persistedCount = 0
    private var softLimitHitCount = 0
    private var replayCount = 0
    private var changeJumpCount = 0
    private var maxObservedChangeDelta = 1
    private var lastPersistedAt: Date?
    private var lastAcknowledgedAt: Date?
    private var lastReplayAt: Date?

    public func recordChangeDelta(_ delta: Int) {
        guard delta > 1 else { return }
        changeJumpCount += 1
        maxObservedChangeDelta = max(maxObservedChangeDelta, delta)
    }

    public func recordSoftLimitHit() {
        softLimitHitCount += 1
    }

    public func recordReplay(count: Int) {
        guard count > 0 else { return }
        replayCount += count
        lastReplayAt = Date()
    }

    public func recordPersistedEnvelope() {
        lastPersistedAt = Date()
    }

    public func recordAcknowledgedEnvelope() {
        lastAcknowledgedAt = Date()
    }

    public func updateQueueSnapshot(pendingCount: Int, activeCount: Int, persistedCount: Int) {
        self.pendingCount = pendingCount
        self.activeCount = activeCount
        self.persistedCount = persistedCount
    }

    public func reset() {
        pendingCount = 0
        activeCount = 0
        persistedCount = 0
        softLimitHitCount = 0
        replayCount = 0
        changeJumpCount = 0
        maxObservedChangeDelta = 1
        lastPersistedAt = nil
        lastAcknowledgedAt = nil
        lastReplayAt = nil
    }

    public func getSummary() async -> ClipboardIngestSummary {
        ClipboardIngestSummary(
            pendingCount: pendingCount,
            activeCount: activeCount,
            persistedCount: persistedCount,
            softLimitHitCount: softLimitHitCount,
            replayCount: replayCount,
            changeJumpCount: changeJumpCount,
            maxObservedChangeDelta: maxObservedChangeDelta,
            lastPersistedAt: lastPersistedAt,
            lastAcknowledgedAt: lastAcknowledgedAt,
            lastReplayAt: lastReplayAt
        )
    }
}

public struct ClipboardIngestSummary: Sendable {
    public let pendingCount: Int
    public let activeCount: Int
    public let persistedCount: Int
    public let softLimitHitCount: Int
    public let replayCount: Int
    public let changeJumpCount: Int
    public let maxObservedChangeDelta: Int
    public let lastPersistedAt: Date?
    public let lastAcknowledgedAt: Date?
    public let lastReplayAt: Date?
}

/// ClipboardMonitor - 系统剪贴板监控服务
/// 符合 v0.md 第1节：后端只提供结构化数据和命令接口
@MainActor
public final class ClipboardMonitor {
    public enum ImagePasteboardWriteMode: Sendable {
        case standard
        case codexOptimized
    }

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

        public enum FileOwnership: Sendable, Equatable {
            case transient
            case durableSpool
        }

        public let type: ClipboardItemType
        public let plainText: String
        public let payload: Payload
        public let note: String?
        public let appBundleID: String?
        public let contentHash: String
        public let sizeBytes: Int
        public let fileSizeBytes: Int?
        public let ingestEnvelopeURL: URL?
        public let ingestID: UUID?
        public let fileOwnership: FileOwnership

        public init(
            type: ClipboardItemType,
            plainText: String,
            payload: Payload,
            note: String? = nil,
            appBundleID: String?,
            contentHash: String,
            sizeBytes: Int,
            fileSizeBytes: Int? = nil,
            ingestEnvelopeURL: URL? = nil,
            ingestID: UUID? = nil,
            fileOwnership: FileOwnership = .transient
        ) {
            self.type = type
            self.plainText = plainText
            self.payload = payload
            self.note = note
            self.appBundleID = appBundleID
            self.contentHash = contentHash
            self.sizeBytes = sizeBytes
            self.fileSizeBytes = fileSizeBytes
            self.ingestEnvelopeURL = ingestEnvelopeURL
            self.ingestID = ingestID
            self.fileOwnership = fileOwnership
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
        let precomputedHash: String?  // 图片等内容的预计算轻量指纹
        let imageDataWasTIFF: Bool

        init(
            type: ClipboardItemType,
            plainText: String,
            rawData: Data?,
            appBundleID: String?,
            sizeBytes: Int,
            precomputedHash: String? = nil,
            imageDataWasTIFF: Bool = false
        ) {
            self.type = type
            self.plainText = plainText
            self.rawData = rawData
            self.appBundleID = appBundleID
            self.sizeBytes = sizeBytes
            self.precomputedHash = precomputedHash
            self.imageDataWasTIFF = imageDataWasTIFF
        }
    }

    private struct PendingIngestEnvelope: Codable, Sendable {
        let id: UUID
        let typeRawValue: String
        let plainText: String
        let appBundleID: String?
        let sizeBytes: Int
        let precomputedHash: String?
        let imageDataWasTIFF: Bool
        let payloadFileName: String?

        var type: ClipboardItemType {
            ClipboardItemType(rawValue: typeRawValue) ?? .other
        }
    }

    public struct TerminalIngestAcknowledgement: Sendable {
        public let ingestID: UUID
        fileprivate let markerURL: URL
        fileprivate let payloadFileName: String?
    }

    public enum IngestAcknowledgementOutcome: Sendable {
        case terminal(TerminalIngestAcknowledgement)
        case rejected
    }

    // MARK: - Properties

    private let pasteboard: NSPasteboard
    nonisolated private let timerBox: TimerBox
    private var lastChangeCount: Int = 0
    private var isMonitoring = false
    private var monitoringSessionID: UInt64 = 0
    private var isCheckingClipboard = false

    private var pendingLargeContent: [URL] = []
    private var trackedPendingEnvelopePaths = Set<String>()
    private var activeIngestTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentTasks = ScopyThresholds.ingestMaxConcurrentTasks
    private let maxPendingItems = ScopyThresholds.ingestMaxPendingItems
    private let queueLock = NSLock()

    private let contentQueue: AsyncBoundedQueue<ClipboardContent>
    public let contentStream: AsyncStream<ClipboardContent>

    private let ingestSpoolDirectory: URL
    nonisolated private static let terminalEnvelopeSuffix = ".envelope.acked"
    nonisolated private static let pendingEnvelopeSuffix = ".envelope.json"
    nonisolated private static let transientWorkPrefix = ".ingest-work-"
    nonisolated private static let corruptEnvelopeSuffix = ".quarantine"
    nonisolated private static let staleControlledArtifactAge: TimeInterval = 24 * 60 * 60
    nonisolated private static let maxControlledArtifactsPerSweep = 256
    private static let protectedPasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword")
    ]

    nonisolated(unsafe) public static var testingAsyncProcessingDelayNs: UInt64 = 0

    // Configuration
    public private(set) var pollingInterval: TimeInterval = 0.5 // 500ms default
    public private(set) var ignoredApps: Set<String> = []

    // MARK: - Initialization

    public convenience init(
        pasteboard: NSPasteboard = .general,
        pollingInterval: TimeInterval? = nil,
        ingestSpoolDirectory: URL? = nil,
        legacyIngestSpoolDirectory: URL? = nil
    ) {
        self.init(
            pasteboard: pasteboard,
            pollingInterval: pollingInterval,
            ingestSpoolDirectory: ingestSpoolDirectory,
            legacyIngestSpoolDirectory: legacyIngestSpoolDirectory,
            spoolAlreadyPrepared: false
        )
    }

    init(
        pasteboard: NSPasteboard,
        pollingInterval: TimeInterval?,
        ingestSpoolDirectory: URL?,
        legacyIngestSpoolDirectory: URL?,
        spoolAlreadyPrepared: Bool
    ) {
        self.pasteboard = pasteboard
        self.timerBox = TimerBox()
        if let pollingInterval {
            self.pollingInterval = max(0.1, min(5.0, pollingInterval))
        }

        let ingestDir: URL
        let legacyIngestDir: URL?
        if let ingestSpoolDirectory {
            ingestDir = ingestSpoolDirectory
            legacyIngestDir = legacyIngestSpoolDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? {
                ScopyLog.monitor.warning("Failed to resolve Application Support; falling back to temporary directory")
                return FileManager.default.temporaryDirectory
            }()
            ingestDir = appSupport
                .appendingPathComponent("Scopy", isDirectory: true)
                .appendingPathComponent("ingest", isDirectory: true)

            legacyIngestDir = legacyIngestSpoolDirectory ?? Self.defaultLegacyIngestSpoolDirectory()
        }
        self.ingestSpoolDirectory = ingestDir
        if !spoolAlreadyPrepared {
            Self.prepareIngestSpoolDirectory(
                ingestDir,
                legacyDirectory: legacyIngestDir
            )
        }

        let queue = AsyncBoundedQueue<ClipboardContent>(capacity: ScopyThresholds.monitorContentStreamMaxBufferedItems)
        self.contentQueue = queue
        self.contentStream = AsyncStream(unfolding: { await queue.dequeue() })
        self.lastChangeCount = pasteboard.changeCount
    }

    nonisolated static func defaultLegacyIngestSpoolDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Scopy", isDirectory: true)
            .appendingPathComponent("ingest", isDirectory: true)
    }

    /// Performs potentially large legacy copies and artifact enumeration outside the monitor's
    /// main-actor lifecycle in production. The public initializer keeps a synchronous fallback for
    /// standalone callers that cannot participate in ClipboardService startup orchestration.
    nonisolated static func prepareIngestSpoolDirectory(
        _ ingestDirectory: URL,
        legacyDirectory: URL?
    ) {
        do {
            try FileManager.default.createDirectory(
                at: ingestDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            ScopyLog.monitor.warning(
                "Failed to create ingest spool directory: \(error.localizedDescription, privacy: .private)"
            )
        }
        if let legacyDirectory {
            migrateLegacyPendingEnvelopes(from: legacyDirectory, to: ingestDirectory)
        }
        cleanupStaleControlledArtifacts(in: ingestDirectory)
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
        replayPendingLargeContentFromDisk()
        installMonitoringTimer()
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
        trackedPendingEnvelopePaths.removeAll()
        publishIngestSnapshotLocked()
    }

    public func setPollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(0.1, min(5.0, interval)) // Clamp between 100ms and 5s
        if isMonitoring {
            installMonitoringTimer()
        }
    }

    @discardableResult
    public func acknowledgeIngestEnvelope(at url: URL) -> IngestAcknowledgementOutcome {
        guard let acknowledgement = Self.transitionEnvelopeToTerminal(
            at: url,
            ingestDirectory: ingestSpoolDirectory
        ) else {
            return .rejected
        }

        queueLock.lock()
        trackedPendingEnvelopePaths.remove(url.path)
        pendingLargeContent.removeAll { $0.path == url.path }
        publishIngestSnapshotLocked()
        queueLock.unlock()
        Task {
            await ClipboardIngestMetrics.shared.recordAcknowledgedEnvelope()
        }
        return .terminal(acknowledgement)
    }

    public func pendingTerminalIngestAcknowledgements(
        limit: Int = 256,
        excluding excludedIDs: Set<UUID> = []
    ) -> [TerminalIngestAcknowledgement] {
        Self.discoverTerminalAcknowledgements(
            in: ingestSpoolDirectory,
            limit: max(0, limit),
            excluding: excludedIDs
        )
    }

    @discardableResult
    public func completeTerminalIngestAcknowledgement(
        _ acknowledgement: TerminalIngestAcknowledgement
    ) -> Bool {
        guard Self.validateTerminalAcknowledgement(
            acknowledgement,
            ingestDirectory: ingestSpoolDirectory
        ) else {
            return false
        }
        return Self.cleanupTerminalAcknowledgement(
            acknowledgement,
            ingestDirectory: ingestSpoolDirectory
        )
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

    public func copyToClipboard(
        data: Data,
        type: NSPasteboard.PasteboardType,
        imageWriteMode: ImagePasteboardWriteMode = .standard
    ) {
        if type == .png {
            guard let imagePayload = Self.makeImagePasteboardPayloadForWrite(data, imageWriteMode: imageWriteMode) else {
                ScopyLog.monitor.error("Failed to normalize image payload as PNG before pasteboard write")
                return
            }

            pasteboard.clearContents()
            let declaredTypes: [NSPasteboard.PasteboardType] = imagePayload.compatibilityTIFFData == nil ? [.png] : [.png, .tiff]
            pasteboard.declareTypes(declaredTypes, owner: nil)

            guard pasteboard.setData(imagePayload.primaryPNGData, forType: .png) else {
                ScopyLog.monitor.error("Failed to write PNG payload to pasteboard")
                return
            }

            if let tiffData = imagePayload.compatibilityTIFFData,
               !pasteboard.setData(tiffData, forType: .tiff) {
                ScopyLog.monitor.warning("Failed to write TIFF fallback for PNG payload")
            }

            lastChangeCount = pasteboard.changeCount
            return
        }

        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        lastChangeCount = pasteboard.changeCount
    }

    public func copyToClipboard(
        imageData data: Data,
        fileURL: URL,
        imageWriteMode: ImagePasteboardWriteMode = .standard
    ) {
        guard let imagePayload = Self.makeImagePasteboardPayloadForWrite(data, imageWriteMode: imageWriteMode) else {
            ScopyLog.monitor.error("Failed to normalize file-backed image payload before pasteboard write")
            return
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([fileURL as NSURL]) else {
            ScopyLog.monitor.warning("Failed to write image file URL to pasteboard; falling back to PNG payload")
            copyToClipboard(data: data, type: .png, imageWriteMode: imageWriteMode)
            return
        }

        let fileListType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.setPropertyList([fileURL.path], forType: fileListType)

        guard pasteboard.setData(imagePayload.primaryPNGData, forType: .png) else {
            ScopyLog.monitor.warning("Failed to add PNG fallback for file-backed image pasteboard payload")
            lastChangeCount = pasteboard.changeCount
            return
        }

        if let tiffData = imagePayload.compatibilityTIFFData,
           !pasteboard.setData(tiffData, forType: .tiff) {
            ScopyLog.monitor.warning("Failed to add TIFF fallback for file-backed image pasteboard payload")
        }

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

    struct ImagePasteboardPayload {
        let primaryPNGData: Data
        let compatibilityTIFFData: Data?
    }

    nonisolated static func makeImagePasteboardPayloadForWrite(
        _ data: Data,
        imageWriteMode: ImagePasteboardWriteMode
    ) -> ImagePasteboardPayload? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let sourceType = CGImageSourceGetType(imageSource) as String?
        if sourceType == UTType.png.identifier {
            switch imageWriteMode {
            case .standard:
                return ImagePasteboardPayload(primaryPNGData: data, compatibilityTIFFData: nil)
            case .codexOptimized:
                if !Self.shouldAddTIFFFallbackForPNGReplay(data) {
                    return ImagePasteboardPayload(primaryPNGData: data, compatibilityTIFFData: nil)
                }
            }
        }

        if sourceType == UTType.png.identifier,
           let tiffData = Self.rasterizeCGImageToStandardTIFF(image) {
            // Keep the stored PNG bytes as the primary representation so replay
            // continues to prefer the pngquant result when available. Only add a
            // rasterized TIFF as a compatibility fallback for narrow readers.
            return ImagePasteboardPayload(primaryPNGData: data, compatibilityTIFFData: tiffData)
        }

        guard let pngData = Self.rasterizeCGImageToStandardPNG(image) else { return nil }
        return ImagePasteboardPayload(primaryPNGData: pngData, compatibilityTIFFData: nil)
    }

    nonisolated static func shouldAddTIFFFallbackForPNGReplay(_ pngData: Data) -> Bool {
        guard let metadata = Self.parsePNGHeaderForReplayPolicy(pngData) else { return true }

        switch metadata.colorType {
        case 2, 6:
            return metadata.bitDepth < 8
        default:
            return true
        }
    }

    private struct PNGReplayHeader {
        let bitDepth: UInt8
        let colorType: UInt8
    }

    nonisolated private static func parsePNGHeaderForReplayPolicy(_ data: Data) -> PNGReplayHeader? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 33, data.prefix(signature.count).elementsEqual(signature) else { return nil }
        guard Self.pngUInt32(data, at: 8) == 13 else { return nil }
        guard Self.pngASCII(data, at: 12, length: 4) == "IHDR" else { return nil }

        guard let bitDepth = Self.pngByte(data, at: 24),
              let colorType = Self.pngByte(data, at: 25) else {
            return nil
        }
        return PNGReplayHeader(bitDepth: bitDepth, colorType: colorType)
    }

    nonisolated private static func pngByte(_ data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    nonisolated private static func pngUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 < data.count else { return nil }
        guard let b0 = Self.pngByte(data, at: offset),
              let b1 = Self.pngByte(data, at: offset + 1),
              let b2 = Self.pngByte(data, at: offset + 2),
              let b3 = Self.pngByte(data, at: offset + 3) else {
            return nil
        }
        return (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
    }

    nonisolated private static func pngASCII(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + length)
        return String(data: data.subdata(in: range), encoding: .ascii)
    }

    nonisolated private static func rasterizeCGImageToStandardPNG(_ image: CGImage) -> Data? {
        guard let context = Self.makeStandardRGBAContext(for: image) else { return nil }

        let width = image.width
        let height = image.height
        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rasterizedImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, rasterizedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated private static func rasterizeCGImageToStandardTIFF(_ image: CGImage) -> Data? {
        guard let context = Self.makeStandardRGBAContext(for: image) else { return nil }

        let width = image.width
        let height = image.height
        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rasterizedImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, rasterizedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated private static func makeStandardRGBAContext(for image: CGImage) -> CGContext? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
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

    // MARK: - Private Methods

    private func checkClipboard() async {
        guard isMonitoring else { return }
        guard !isCheckingClipboard else { return }
        let sessionID = monitoringSessionID
        isCheckingClipboard = true
        defer { isCheckingClipboard = false }

        let currentChangeCount = pasteboard.changeCount
        let previousChangeCount = lastChangeCount

        guard currentChangeCount != previousChangeCount else { return }
        let delta = currentChangeCount - previousChangeCount
        if delta > 1 {
            ScopyLog.monitor.debug("Pasteboard changeCount jumped by \(delta) (prev=\(previousChangeCount), current=\(currentChangeCount))")
            Task {
                await ClipboardIngestMetrics.shared.recordChangeDelta(delta)
            }
        }

        if pasteboard.pasteboardItems?.contains(where: {
            $0.availableType(from: Self.protectedPasteboardTypes) != nil
        }) == true {
            lastChangeCount = currentChangeCount
            return
        }

        // 快速提取原始数据（在主线程）
        let extractStart = ProcessInfo.processInfo.systemUptime
        guard let rawData = await extractRawData(from: pasteboard) else { return }
        let extractMs = (ProcessInfo.processInfo.systemUptime - extractStart) * 1000
        let extractSummary = "\(rawData.type.rawValue) \(rawData.sizeBytes) bytes, main-thread wait \(Int(extractMs)) ms"
        ScopyLog.monitor.info("Capture extract \(extractSummary, privacy: .public)")

        // Check if we should ignore this app
        if let appID = rawData.appBundleID, ignoredApps.contains(appID) {
            lastChangeCount = currentChangeCount
            return
        }

        // Skip empty content
        guard !rawData.plainText.isEmpty || (rawData.rawData != nil && !rawData.rawData!.isEmpty) else {
            lastChangeCount = currentChangeCount
            return
        }

        // v0.10.4: 根据内容类型和大小决定处理方式
        // 1. 图片一律走后台 SHA256，避免轻指纹误判
        // 2. 所有大内容（包括非图片）都异步处理，避免主线程阻塞
        // 3. 只有小内容在主线程同步处理
        if rawData.type == .image || rawData.sizeBytes >= ScopyThresholds.ingestHashOffloadBytes {
            // Persist the durable envelope off the main actor before scheduling ingest work.
            guard await processLargeContentAsync(rawData) else { return }
            // A stop/start while persistence was suspended owns its own pasteboard baseline.
            // The committed envelope is still queued (or replayed on the next start), but the
            // older poll must not overwrite the new session's change count.
            if monitoringSessionID == sessionID {
                lastChangeCount = currentChangeCount
            }
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
            sizeBytes: rawData.sizeBytes
        )
        await contentQueue.enqueue(content)
        lastChangeCount = currentChangeCount
    }

    /// Persists large content away from the main actor, then registers the durable envelope.
    private func processLargeContentAsync(_ rawData: RawClipboardData) async -> Bool {
        let envelopeURL: URL
        let ingestDirectory = ingestSpoolDirectory
        do {
            envelopeURL = try await Task.detached(priority: .userInitiated) {
                try Self.persistPendingEnvelope(for: rawData, in: ingestDirectory)
            }.value
        } catch {
            ScopyLog.monitor.error("Failed to persist ingest envelope: \(error.localizedDescription, privacy: .private)")
            return false
        }

        await ClipboardIngestMetrics.shared.recordPersistedEnvelope()

        // A completed envelope is durable. If monitoring stopped while the write was in flight,
        // leave it on disk for the next replay instead of starting work in a stopped session.
        guard isMonitoring else { return true }

        return registerPersistedEnvelope(envelopeURL)
    }

    private func registerPersistedEnvelope(_ envelopeURL: URL) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }

        // Best-effort cleanup: remove cancelled tasks.
        if !activeIngestTasks.isEmpty {
            activeIngestTasks = Dictionary(uniqueKeysWithValues: activeIngestTasks.filter { !$0.value.isCancelled })
        }

        let inserted = trackedPendingEnvelopePaths.insert(envelopeURL.path).inserted
        guard inserted else { return true }

        if pendingLargeContent.count >= maxPendingItems {
            ScopyLog.monitor.error(
                "Ingest backlog exceeded soft limit (\(self.maxPendingItems, privacy: .public)); keeping durable backlog on disk"
            )
            Task {
                await ClipboardIngestMetrics.shared.recordSoftLimitHit()
            }
        }

        pendingLargeContent.append(envelopeURL)
        publishIngestSnapshotLocked()
        startNextIngestTasksIfNeeded()
        return true
    }

    private func startNextIngestTasksIfNeeded() {
        while activeIngestTasks.count < maxConcurrentTasks, !pendingLargeContent.isEmpty {
            let envelopeURL = pendingLargeContent.removeFirst()

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

                if Self.testingAsyncProcessingDelayNs > 0 {
                    try? await Task.sleep(nanoseconds: Self.testingAsyncProcessingDelayNs)
                }

                guard let envelope = Self.loadValidatedEnvelope(
                    from: envelopeURL,
                    ingestDirectory: ingestDirectory,
                    suffix: Self.pendingEnvelopeSuffix
                ) else {
                    await MainActor.run { [weak self] in
                        self?.discardIngestEnvelope(at: envelopeURL)
                    }
                    return
                }

                let originalPayloadData = Self.loadPendingPayload(from: envelope, ingestDirectory: ingestDirectory)
                if envelope.payloadFileName != nil, originalPayloadData == nil {
                    ScopyLog.monitor.error(
                        "Discarding pending ingest envelope because payload file is missing: \(envelopeURL.lastPathComponent, privacy: .public)"
                    )
                    await MainActor.run { [weak self] in
                        self?.discardIngestEnvelope(at: envelopeURL)
                    }
                    return
                }
                var payloadData = originalPayloadData
                var plainText = envelope.plainText
                var sizeBytes = envelope.sizeBytes

                if envelope.type == .image, let imageData = payloadData {
                    if envelope.imageDataWasTIFF, let pngData = Self.convertTIFFToPNG(imageData) {
                        payloadData = pngData
                    } else {
                        payloadData = imageData
                    }
                    sizeBytes = payloadData?.count ?? imageData.count
                    plainText = "[Image: \(Self.formatBytes(sizeBytes))]"
                }

                let hash = Self.contentHash(
                    type: envelope.type,
                    plainText: plainText,
                    payloadData: payloadData,
                    precomputedHash: envelope.precomputedHash
                )

                let preferredPayloadURL: URL? = {
                    guard payloadData == originalPayloadData else { return nil }
                    return Self.pendingPayloadURL(for: envelope, ingestDirectory: ingestDirectory)
                }()

                let builtPayload = Self.buildPayload(
                    type: envelope.type,
                    data: payloadData,
                    sizeBytes: sizeBytes,
                    ingestDirectory: ingestDirectory,
                    spoolThresholdBytes: spoolThresholdBytes,
                    preferredFileURL: preferredPayloadURL
                )

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
                    Self.cleanupPayloadIfNeeded(
                        builtPayload.payload,
                        ownership: builtPayload.ownership
                    )
                    return
                }

                let content = ClipboardContent(
                    type: envelope.type,
                    plainText: resolvedPlainText,
                    payload: builtPayload.payload,
                    appBundleID: envelope.appBundleID,
                    contentHash: hash,
                    sizeBytes: resolvedSizeBytes,
                    ingestEnvelopeURL: envelopeURL,
                    ingestID: envelope.id,
                    fileOwnership: builtPayload.ownership
                )

                await contentQueue.enqueue(content)
            }

            activeIngestTasks[taskID] = task
            publishIngestSnapshotLocked()
        }
    }

    private func finishIngestTask(id: UUID) {
        queueLock.lock()
        defer { queueLock.unlock() }

        activeIngestTasks.removeValue(forKey: id)
        publishIngestSnapshotLocked()
        startNextIngestTasksIfNeeded()
    }

    private struct BuiltPayload: Sendable {
        let payload: ClipboardContent.Payload
        let ownership: ClipboardContent.FileOwnership
    }

    nonisolated private static func buildPayload(
        type: ClipboardItemType,
        data: Data?,
        sizeBytes: Int,
        ingestDirectory: URL,
        spoolThresholdBytes: Int,
        preferredFileURL: URL?
    ) -> BuiltPayload {
        guard let data else { return BuiltPayload(payload: .none, ownership: .transient) }

        guard sizeBytes >= spoolThresholdBytes else {
            return BuiltPayload(payload: .data(data), ownership: .transient)
        }

        if let preferredFileURL, FileManager.default.fileExists(atPath: preferredFileURL.path) {
            return BuiltPayload(payload: .file(preferredFileURL), ownership: .durableSpool)
        }

        let ext: String
        switch type {
        case .image: ext = "png"
        case .rtf: ext = "rtf"
        case .html: ext = "html"
        default: ext = "dat"
        }

        let fileURL = ingestDirectory.appendingPathComponent(
            "\(transientWorkPrefix)\(UUID().uuidString).\(ext)"
        )
        do {
            try StorageService.writeAtomically(data, to: fileURL.path)
            return BuiltPayload(payload: .file(fileURL), ownership: .transient)
        } catch {
            ScopyLog.monitor.warning("Failed to spool ingest payload: \(error.localizedDescription, privacy: .private)")
            return BuiltPayload(payload: .data(data), ownership: .transient)
        }
    }

    nonisolated private static func cleanupPayloadIfNeeded(
        _ payload: ClipboardContent.Payload,
        ownership: ClipboardContent.FileOwnership
    ) {
        guard ownership == .transient else { return }
        guard case .file(let url) = payload else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func installMonitoringTimer() {
        if let timer = timerBox.take() {
            timer.invalidate()
        }

        let timer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkClipboard()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timerBox.set(timer)
    }

    private func replayPendingLargeContentFromDisk() {
        let persisted = Self.discoverPendingEnvelopeURLs(in: ingestSpoolDirectory)
        guard !persisted.isEmpty else { return }

        queueLock.lock()
        defer { queueLock.unlock() }

        var replayed = 0
        for envelopeURL in persisted where trackedPendingEnvelopePaths.insert(envelopeURL.path).inserted {
            pendingLargeContent.append(envelopeURL)
            replayed += 1
        }
        publishIngestSnapshotLocked()
        startNextIngestTasksIfNeeded()
        if replayed > 0 {
            Task {
                await ClipboardIngestMetrics.shared.recordReplay(count: replayed)
            }
        }
    }

    nonisolated private static func persistPendingEnvelope(
        for rawData: RawClipboardData,
        in ingestDirectory: URL
    ) throws -> URL {
        let id = UUID()
        let payloadFileName = rawData.rawData.map { _ in "\(id.uuidString).payload" }
        var payloadURL: URL?
        var envelopeCommitted = false
        defer {
            if !envelopeCommitted, let payloadURL {
                try? FileManager.default.removeItem(at: payloadURL)
            }
        }
        if let payloadData = rawData.rawData, let payloadFileName {
            let url = ingestDirectory.appendingPathComponent(payloadFileName)
            payloadURL = url
            try StorageService.writeAtomically(payloadData, to: url.path)
        }

        let envelope = PendingIngestEnvelope(
            id: id,
            typeRawValue: rawData.type.rawValue,
            plainText: rawData.plainText,
            appBundleID: rawData.appBundleID,
            sizeBytes: rawData.sizeBytes,
            precomputedHash: rawData.precomputedHash,
            imageDataWasTIFF: rawData.imageDataWasTIFF,
            payloadFileName: payloadFileName
        )

        let envelopeURL = ingestDirectory.appendingPathComponent("\(id.uuidString).envelope.json")
        try Self.writePendingEnvelope(envelope, to: envelopeURL)
        envelopeCommitted = true
        return envelopeURL
    }

    private func discardIngestEnvelope(at url: URL) {
        switch acknowledgeIngestEnvelope(at: url) {
        case .terminal(let acknowledgement):
            completeTerminalIngestAcknowledgement(acknowledgement)
        case .rejected:
            Self.quarantinePendingEnvelope(at: url, ingestDirectory: ingestSpoolDirectory)
            queueLock.lock()
            trackedPendingEnvelopePaths.remove(url.path)
            pendingLargeContent.removeAll { $0.path == url.path }
            publishIngestSnapshotLocked()
            queueLock.unlock()
        }
    }

    private func publishIngestSnapshotLocked() {
        let pendingCount = pendingLargeContent.count
        let activeCount = activeIngestTasks.count
        let persistedCount = trackedPendingEnvelopePaths.count
        Task {
            await ClipboardIngestMetrics.shared.updateQueueSnapshot(
                pendingCount: pendingCount,
                activeCount: activeCount,
                persistedCount: persistedCount
            )
        }
    }

    nonisolated private static func writePendingEnvelope(_ envelope: PendingIngestEnvelope, to url: URL) throws {
        let data = try JSONEncoder().encode(envelope)
        try StorageService.writeAtomically(data, to: url.path)
    }

    nonisolated private static func loadPendingEnvelope(from url: URL) -> PendingIngestEnvelope? {
        guard let data = BestEffortFileOps.loadData(
            from: url,
            logger: ScopyLog.monitor,
            operation: "loadPendingEnvelope.read"
        ) else {
            return nil
        }
        return BestEffortFileOps.decodeJSON(
            PendingIngestEnvelope.self,
            from: data,
            logger: ScopyLog.monitor,
            operation: "loadPendingEnvelope.decode",
            path: url.path
        )
    }

    nonisolated private static func discoverPendingEnvelopeURLs(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.lastPathComponent.hasSuffix(".envelope.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func pendingPayloadURL(for envelope: PendingIngestEnvelope, ingestDirectory: URL) -> URL? {
        guard let payloadFileName = envelope.payloadFileName else { return nil }
        guard payloadFileName == "\(envelope.id.uuidString).payload" else { return nil }
        let url = ingestDirectory.appendingPathComponent(payloadFileName)
        guard validateOwnedRegularFile(
            url,
            in: ingestDirectory,
            expectedFileName: payloadFileName
        ) else {
            return nil
        }
        return url
    }

    nonisolated private static func loadPendingPayload(from envelope: PendingIngestEnvelope, ingestDirectory: URL) -> Data? {
        guard let payloadURL = pendingPayloadURL(for: envelope, ingestDirectory: ingestDirectory) else {
            return nil
        }
        return BestEffortFileOps.loadData(
            from: payloadURL,
            options: [.mappedIfSafe],
            logger: ScopyLog.monitor,
            operation: "loadPendingPayload.read"
        )
    }

    nonisolated private static func loadValidatedEnvelope(
        from url: URL,
        ingestDirectory: URL,
        suffix: String
    ) -> PendingIngestEnvelope? {
        guard let pathID = validateOwnedEnvelopeURL(
            url,
            in: ingestDirectory,
            suffix: suffix,
            requireExistingRegularFile: true
        ), let envelope = loadPendingEnvelope(from: url), envelope.id == pathID else {
            return nil
        }
        if let payloadFileName = envelope.payloadFileName,
           payloadFileName != "\(envelope.id.uuidString).payload" {
            return nil
        }
        return envelope
    }

    nonisolated private static func validateOwnedEnvelopeURL(
        _ url: URL,
        in ingestDirectory: URL,
        suffix: String,
        requireExistingRegularFile: Bool
    ) -> UUID? {
        let directory = ingestDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == directory.path else { return nil }
        guard candidate.lastPathComponent.hasSuffix(suffix) else { return nil }
        let idText = String(candidate.lastPathComponent.dropLast(suffix.count))
        guard let id = UUID(uuidString: idText) else { return nil }
        guard !requireExistingRegularFile || validateOwnedRegularFile(
            candidate,
            in: directory,
            expectedFileName: candidate.lastPathComponent
        ) else {
            return nil
        }
        return id
    }

    nonisolated private static func validateOwnedRegularFile(
        _ url: URL,
        in directory: URL,
        expectedFileName: String
    ) -> Bool {
        let ownedRoot = directory.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.lastPathComponent == expectedFileName,
              candidate.deletingLastPathComponent().path == ownedRoot.path else {
            return false
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return false
        }
        let resolvedRoot = ownedRoot.resolvingSymlinksInPath().path
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        return resolvedCandidate.deletingLastPathComponent().path == resolvedRoot
    }

    nonisolated private static func transitionEnvelopeToTerminal(
        at pendingURL: URL,
        ingestDirectory: URL
    ) -> TerminalIngestAcknowledgement? {
        guard let pathID = validateOwnedEnvelopeURL(
            pendingURL,
            in: ingestDirectory,
            suffix: pendingEnvelopeSuffix,
            requireExistingRegularFile: false
        ) else {
            return nil
        }
        let markerURL = ingestDirectory.appendingPathComponent(
            "\(pathID.uuidString)\(terminalEnvelopeSuffix)"
        )

        if FileManager.default.fileExists(atPath: pendingURL.path) {
            guard loadValidatedEnvelope(
                from: pendingURL,
                ingestDirectory: ingestDirectory,
                suffix: pendingEnvelopeSuffix
            ) != nil else {
                return nil
            }
            guard !FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
            do {
                try FileManager.default.moveItem(at: pendingURL, to: markerURL)
            } catch {
                ScopyLog.monitor.warning(
                    "Failed to transition ingest envelope to terminal state: \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }

        guard let envelope = loadValidatedEnvelope(
            from: markerURL,
            ingestDirectory: ingestDirectory,
            suffix: terminalEnvelopeSuffix
        ) else {
            return nil
        }
        return TerminalIngestAcknowledgement(
            ingestID: envelope.id,
            markerURL: markerURL,
            payloadFileName: envelope.payloadFileName
        )
    }

    nonisolated private static func discoverTerminalAcknowledgements(
        in directory: URL,
        limit: Int,
        excluding excludedIDs: Set<UUID>
    ) -> [TerminalIngestAcknowledgement] {
        guard limit > 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return Array(urls
            .filter { $0.lastPathComponent.hasSuffix(terminalEnvelopeSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { markerURL in
                guard let envelope = loadValidatedEnvelope(
                    from: markerURL,
                    ingestDirectory: directory,
                    suffix: terminalEnvelopeSuffix
                ) else {
                    return nil
                }
                return TerminalIngestAcknowledgement(
                    ingestID: envelope.id,
                    markerURL: markerURL,
                    payloadFileName: envelope.payloadFileName
                )
            }
            .filter { !excludedIDs.contains($0.ingestID) }
            .prefix(limit))
    }

    nonisolated private static func validateTerminalAcknowledgement(
        _ acknowledgement: TerminalIngestAcknowledgement,
        ingestDirectory: URL
    ) -> Bool {
        guard let envelope = loadValidatedEnvelope(
            from: acknowledgement.markerURL,
            ingestDirectory: ingestDirectory,
            suffix: terminalEnvelopeSuffix
        ) else {
            return false
        }
        return envelope.id == acknowledgement.ingestID &&
            envelope.payloadFileName == acknowledgement.payloadFileName
    }

    nonisolated private static func cleanupTerminalAcknowledgement(
        _ acknowledgement: TerminalIngestAcknowledgement,
        ingestDirectory: URL
    ) -> Bool {
        if let payloadFileName = acknowledgement.payloadFileName,
           payloadFileName == "\(acknowledgement.ingestID.uuidString).payload" {
            let payloadURL = ingestDirectory.appendingPathComponent(payloadFileName)
            if FileManager.default.fileExists(atPath: payloadURL.path) {
                guard validateOwnedRegularFile(
                    payloadURL,
                    in: ingestDirectory,
                    expectedFileName: payloadFileName
                ) else {
                    return false
                }
                do {
                    try FileManager.default.removeItem(at: payloadURL)
                } catch {
                    ScopyLog.monitor.warning(
                        "Failed to remove terminal ingest payload: \(error.localizedDescription, privacy: .private)"
                    )
                    return false
                }
                guard !FileManager.default.fileExists(atPath: payloadURL.path) else { return false }
            }
        }
        guard validateOwnedRegularFile(
            acknowledgement.markerURL,
            in: ingestDirectory,
            expectedFileName: acknowledgement.markerURL.lastPathComponent
        ) else {
            return false
        }
        BestEffortFileOps.removeItem(
            at: acknowledgement.markerURL,
            logger: ScopyLog.monitor,
            operation: "cleanupTerminalIngest.removeMarker"
        )
        return !FileManager.default.fileExists(atPath: acknowledgement.markerURL.path)
    }

    nonisolated private static func quarantinePendingEnvelope(
        at url: URL,
        ingestDirectory: URL
    ) {
        guard validateOwnedEnvelopeURL(
            url,
            in: ingestDirectory,
            suffix: pendingEnvelopeSuffix,
            requireExistingRegularFile: true
        ) != nil else {
            return
        }
        let quarantineURL = ingestDirectory.appendingPathComponent(
            url.lastPathComponent + corruptEnvelopeSuffix
        )
        guard !FileManager.default.fileExists(atPath: quarantineURL.path) else { return }
        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
        } catch {
            ScopyLog.monitor.warning(
                "Failed to quarantine corrupt ingest envelope: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    nonisolated static func createTransientWorkCopy(
        for content: ClipboardContent,
        preferredExtension: String = "png"
    ) throws -> URL {
        guard content.fileOwnership == .durableSpool,
              case .file(let sourceURL) = content.payload,
              let ingestID = content.ingestID,
              let envelopeURL = content.ingestEnvelopeURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = envelopeURL.deletingLastPathComponent()
        guard validateOwnedEnvelopeURL(
            envelopeURL,
            in: directory,
            suffix: pendingEnvelopeSuffix,
            requireExistingRegularFile: true
        ) == ingestID,
        validateOwnedRegularFile(
            sourceURL,
            in: directory,
            expectedFileName: "\(ingestID.uuidString).payload"
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let safeExtension = preferredExtension.lowercased().allSatisfy { $0.isLetter || $0.isNumber }
            ? preferredExtension.lowercased()
            : "dat"
        let workURL = directory.appendingPathComponent(
            "\(transientWorkPrefix)\(UUID().uuidString).\(safeExtension)"
        )
        try FileManager.default.copyItem(at: sourceURL, to: workURL)
        return workURL
    }

    nonisolated private static func migrateLegacyPendingEnvelopes(
        from legacyDirectory: URL,
        to destinationDirectory: URL
    ) {
        guard legacyDirectory.standardizedFileURL.path != destinationDirectory.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: legacyDirectory.path) else {
            return
        }
        let pendingURLs = discoverPendingEnvelopeURLs(in: legacyDirectory)
        for legacyEnvelopeURL in pendingURLs {
            guard let envelope = loadValidatedEnvelope(
                from: legacyEnvelopeURL,
                ingestDirectory: legacyDirectory,
                suffix: pendingEnvelopeSuffix
            ) else {
                continue
            }

            var legacyPayloadURL: URL?
            if envelope.payloadFileName != nil {
                guard let payloadURL = pendingPayloadURL(
                    for: envelope,
                    ingestDirectory: legacyDirectory
                ) else {
                    continue
                }
                legacyPayloadURL = payloadURL
                let destinationPayloadURL = destinationDirectory.appendingPathComponent(
                    payloadURL.lastPathComponent
                )
                guard copyOwnedMigrationFileIfNeeded(
                    from: payloadURL,
                    to: destinationPayloadURL,
                    destinationDirectory: destinationDirectory
                ) else {
                    continue
                }
            }

            let destinationEnvelopeURL = destinationDirectory.appendingPathComponent(
                legacyEnvelopeURL.lastPathComponent
            )
            guard copyOwnedMigrationFileIfNeeded(
                from: legacyEnvelopeURL,
                to: destinationEnvelopeURL,
                destinationDirectory: destinationDirectory
            ), loadValidatedEnvelope(
                from: destinationEnvelopeURL,
                ingestDirectory: destinationDirectory,
                suffix: pendingEnvelopeSuffix
            ) != nil else {
                continue
            }

            if let legacyPayloadURL {
                try? FileManager.default.removeItem(at: legacyPayloadURL)
            }
            try? FileManager.default.removeItem(at: legacyEnvelopeURL)
        }
    }

    nonisolated private static func copyOwnedMigrationFileIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        destinationDirectory: URL
    ) -> Bool {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard validateOwnedRegularFile(
                destinationURL,
                in: destinationDirectory,
                expectedFileName: destinationURL.lastPathComponent
            ) else {
                return false
            }
            return FileManager.default.contentsEqual(
                atPath: sourceURL.path,
                andPath: destinationURL.path
            )
        }

        let temporaryURL = destinationDirectory.appendingPathComponent(
            "\(transientWorkPrefix)\(UUID().uuidString).migration.tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            guard validateOwnedRegularFile(
                destinationURL,
                in: destinationDirectory,
                expectedFileName: destinationURL.lastPathComponent
            ) else {
                return false
            }
            return FileManager.default.contentsEqual(
                atPath: sourceURL.path,
                andPath: destinationURL.path
            )
        } catch {
            ScopyLog.monitor.warning(
                "Failed to migrate a legacy ingest artifact: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    nonisolated private static func cleanupStaleControlledArtifacts(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-staleControlledArtifactAge)
        var removed = 0
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard removed < maxControlledArtifactsPerSweep else { break }
            let name = url.lastPathComponent
            let orphanPayloadID = standalonePayloadID(from: name)
            guard isControlledTransientArtifactName(name) || orphanPayloadID != nil else { continue }
            if let orphanPayloadID,
               hasEnvelopeAuthority(for: orphanPayloadID, in: directory) {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff,
                  validateOwnedRegularFile(url, in: directory, expectedFileName: name) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                ScopyLog.monitor.warning(
                    "Failed to remove stale ingest work artifact: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    nonisolated private static func isControlledTransientArtifactName(_ name: String) -> Bool {
        if name.hasPrefix(transientWorkPrefix) { return true }
        guard name.hasSuffix(".tmp") else { return false }
        let base = String(name.dropLast(4))
        if base.hasSuffix(".payload") {
            return UUID(uuidString: String(base.dropLast(".payload".count))) != nil
        }
        if base.hasSuffix(pendingEnvelopeSuffix) {
            return UUID(uuidString: String(base.dropLast(pendingEnvelopeSuffix.count))) != nil
        }
        return false
    }

    nonisolated private static func standalonePayloadID(from name: String) -> UUID? {
        guard name.hasSuffix(".payload") else { return nil }
        return UUID(uuidString: String(name.dropLast(".payload".count)))
    }

    /// A pending, terminal, or quarantined envelope remains the conservative authority for its
    /// payload. Only an aged UUID payload with no such sibling is an owned crash orphan.
    nonisolated private static func hasEnvelopeAuthority(for id: UUID, in directory: URL) -> Bool {
        let base = id.uuidString
        let authorityNames = [
            base + pendingEnvelopeSuffix,
            base + terminalEnvelopeSuffix,
            base + pendingEnvelopeSuffix + corruptEnvelopeSuffix
        ]
        return authorityNames.contains { name in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path
            )
        }
    }

    /// 快速提取原始数据（不计算哈希，避免阻塞主线程）
    /// 注意：检测顺序很重要！文件复制时剪贴板同时包含 file URL 和 plain text，
    /// 必须先检测 file URL，否则会被误识别为文本。
    private func extractRawData(from pasteboard: NSPasteboard) async -> RawClipboardData? {
        let appBundleID = getFrontmostAppBundleID()

        // 检测顺序（默认）：File URLs > Image > RTF > HTML > Plain text
        // Plain text 必须放最后，因为其他类型通常也包含文本表示
        //
        // 例外：Office/Excel 复制单元格时，经常同时提供“图片预览 + HTML/RTF/文本”。
        // 此时如果优先选 Image，会导致历史记录变成图片，粘贴行为也不符合用户预期（表格应保持为富文本/文本）。
        //
        // 这里采用“仅在检测到明显的表格/Office 富文本信号时”才让 Image 退到后面，
        // 以避免影响浏览器/设计工具等真正的图片复制场景。

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let shouldPreferImageOverFileURLs = shouldPreferImageOverFileURLs(fileURLs: fileURLs, from: pasteboard)

        // 1. File URLs (最高优先级 - 文件复制总是带有文本表示)
        // 例外：部分 App（如 IM）复制图片时会同时给“临时图片文件路径 + 图片二进制”，这类场景应保留图片语义。
        if !fileURLs.isEmpty, !shouldPreferImageOverFileURLs {
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

        let shouldPreferRichTypesOverImage = shouldPreferRichTypesOverImage(from: pasteboard)

        // 2. Image (PNG, TIFF, etc.) - 默认优先 PNG；TIFF 转 PNG 延迟到后台（避免主线程重编码）
        // v0.19: 图片统一使用 SHA256 去重（在后台线程计算），移除无用的轻量指纹
        if !shouldPreferRichTypesOverImage, let imageResult = extractImageDataForIngest(from: pasteboard, candidateFileURL: fileURLs.first) {
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

        // 3-5. RTF / HTML / plain text: read the representations here, process them off the main thread.
        // A 1 MB rich copy otherwise blocks the main thread for about two seconds.
        let rtfData = pasteboard.data(forType: .rtf)
        let htmlData = pasteboard.data(forType: .html)
        let string = pasteboard.string(forType: .string)
        if rtfData != nil || htmlData != nil || string != nil {
            let parseHTMLOnMain: @MainActor @Sendable (Data) -> String? = { [self] data in
                extractPlainTextFromHTML(data)
            }
            let textRawData = await Task.detached(priority: .userInitiated) {
                await Self.makeTextRawData(
                    rtfData: rtfData,
                    htmlData: htmlData,
                    string: string,
                    appBundleID: appBundleID,
                    parseHTMLOnMain: parseHTMLOnMain
                )
            }.value
            if let textRawData {
                return textRawData
            }
        }

        // 6. Image（兜底）
        // 如果上面没有任何富文本/文本可用，再回退到图片，确保复制图表/截图等场景不丢失内容。
        if shouldPreferRichTypesOverImage, let imageResult = extractImageDataForIngest(from: pasteboard, candidateFileURL: fileURLs.first) {
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

        return nil
    }

    /// 为 RawClipboardData 计算哈希（用于小内容，在主线程同步执行）
    private func computeHash(_ rawData: RawClipboardData) -> String {
        Self.contentHash(
            type: rawData.type,
            plainText: rawData.plainText,
            payloadData: rawData.rawData,
            precomputedHash: rawData.precomputedHash
        )
    }

    /// Central dedup key policy, shared by immediate reads and durable ingest replay.
    nonisolated private static func contentHash(
        type: ClipboardItemType,
        plainText: String,
        payloadData: Data?,
        precomputedHash: String?
    ) -> String {
        if let precomputedHash {
            return precomputedHash
        }

        // Text, RTF and HTML intentionally deduplicate by normalized visible text. File
        // captures need a distinct namespace because the same path string has different
        // replay semantics when copied as plain text.
        switch type {
        case .text, .rtf, .html:
            if !plainText.isEmpty {
                return computeHashStatic(Data(plainText.utf8))
            }
            if let payloadData {
                return computeHashStatic(payloadData)
            }
            return computeHashStatic(Data())
        case .file:
            return "file:" + computeHashStatic(Data(plainText.utf8))
        case .image:
            if let payloadData {
                return computeHashStatic(payloadData)
            }
            return computeHashStatic(Data(plainText.utf8))
        case .other:
            if let payloadData {
                return computeHashStatic(payloadData)
            }
            return computeHashStatic(Data(plainText.utf8))
        }
    }

    /// 提取剪贴板内容（包含哈希计算）
    /// 注意：检测顺序与 extractRawData 保持一致
    private func extractContent(from pasteboard: NSPasteboard) -> ClipboardContent? {
        let appBundleID = getFrontmostAppBundleID()

        // 检测顺序（默认）：File URLs > Image > RTF > HTML > Plain text
        // Plain text 必须放最后，因为其他类型通常也包含文本表示
        //
        // 例外：当剪贴板同时包含“图片 + Office 表格类富文本/文本”时（常见于 Excel 复制单元格），
        // 让图片降级为兜底，优先保留表格的富文本/文本语义（详见 extractRawData 注释）。

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let shouldPreferImageOverFileURLs = shouldPreferImageOverFileURLs(fileURLs: fileURLs, from: pasteboard)

        // 1. File URLs (最高优先级)
        // 例外：临时图片路径与图片二进制并存时（常见于聊天/IM 客户端）优先按图片处理。
        if !fileURLs.isEmpty, !shouldPreferImageOverFileURLs {
            let paths = fileURLs.map { $0.path }.joined(separator: "\n")
            let hash = Self.contentHash(
                type: .file,
                plainText: paths,
                payloadData: nil,
                precomputedHash: nil
            )
            // 序列化文件 URL 以便后续恢复
            let urlData = Self.serializeFileURLs(fileURLs)
            return ClipboardContent(
                type: .file,
                plainText: paths,
                payload: urlData.map(ClipboardContent.Payload.data) ?? .none,
                appBundleID: appBundleID,
                contentHash: hash,
                sizeBytes: paths.utf8.count + (urlData?.count ?? 0)
            )
        }

        let shouldPreferRichTypesOverImage = shouldPreferRichTypesOverImage(from: pasteboard)

        // 2. Image (PNG, TIFF, etc.) - 默认优先 PNG，TIFF 转为 PNG 避免存储膨胀
        if !shouldPreferRichTypesOverImage, let imageResult = extractOptimalImageData(from: pasteboard, candidateFileURL: fileURLs.first) {
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
            let rtfPlainText = Self.normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: rtfData, type: .rtf))
            let plainText: String
            if let htmlData = pasteboard.data(forType: .html) {
                let htmlPlainText = Self.normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: htmlData, type: .html))
                plainText = Self.shouldPreferRichPlainText(htmlPlainText, over: rtfPlainText) ? htmlPlainText : rtfPlainText
            } else {
                plainText = rtfPlainText
            }
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
            let plainText = Self.normalizeText(extractPreferredPlainText(from: pasteboard, richTextData: htmlData, type: .html))
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
            let normalizedText = Self.normalizeText(string)
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

        // 6. Image（兜底）
        if shouldPreferRichTypesOverImage, let imageResult = extractOptimalImageData(from: pasteboard, candidateFileURL: fileURLs.first) {
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

        return nil
    }

    private func shouldPreferRichTypesOverImage(from pasteboard: NSPasteboard) -> Bool {
        // 仅当剪贴板确实包含图片时才需要此判断，避免无谓开销。
        guard let types = pasteboard.types, types.contains(.png) || types.contains(.tiff) else {
            return false
        }

        let hasHTML = types.contains(.html)
        let hasRTF = types.contains(.rtf)
        let hasString = types.contains(.string)
        guard hasHTML || hasRTF || hasString else { return false }

        // Office/Excel 复制通常会带一些自定义的 pasteboard types；优先用 types 快速识别。
        if types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("excel") }) {
            return true
        }

        if hasHTML, let htmlData = pasteboard.data(forType: .html), Self.htmlLooksLikeOfficeSpreadsheet(htmlData) {
            return true
        }

        if hasRTF, let rtfData = pasteboard.data(forType: .rtf), Self.rtfLooksLikeTable(rtfData) {
            return true
        }

        if hasString, let string = pasteboard.string(forType: .string), Self.stringLooksLikeTabularData(string) {
            return true
        }

        return false
    }

    private func shouldPreferImageOverFileURLs(fileURLs: [URL], from pasteboard: NSPasteboard) -> Bool {
        guard fileURLs.count == 1 else { return false }
        let fileURL = fileURLs[0]
        guard Self.isLikelyTemporaryImageFileURL(fileURL) else { return false }
        if extractImageDataForIngest(from: pasteboard, candidateFileURL: nil) != nil {
            return true
        }
        return Self.loadImageFileDataAsPNG(fileURL) != nil
    }

    nonisolated static func isLikelyTemporaryImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"
        ]
        guard imageExtensions.contains(ext) else { return false }

        let path = url.standardizedFileURL.path.lowercased()
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") { return true }
        if path.contains("/var/folders/") { return true }
        if path.contains("/library/caches/") { return true }
        if path.contains("/library/containers/com.tencent.xinwechat/"),
           (path.contains("/temp/") || path.contains("/rwtemp/") || path.contains("/xwechat_files/")) {
            return true
        }
        if path.contains("/xwechat_files/"),
           (path.contains("/temp/") || path.contains("/rwtemp/")) {
            return true
        }
        return false
    }

    nonisolated static func loadImageFileDataAsPNG(_ url: URL) -> Data? {
        guard isLikelyTemporaryImageFileURL(url) else { return nil }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return nil
        }

        if PngquantService.isLikelyPNG(fileData) {
            return fileData
        }

        return convertTIFFToPNG(fileData)
    }

    nonisolated private static func htmlLooksLikeOfficeSpreadsheet(_ htmlData: Data) -> Bool {
        // 仅扫描前面一小段，避免大表格导致不必要的开销。
        let sample = String(decoding: htmlData.prefix(16 * 1024), as: UTF8.self).lowercased()

        // 复制图片（浏览器/设计工具）常见为 <img ...>；即便 HTML 包在 table 中，也不应抢走 image。
        if sample.contains("<img") { return false }

        // Excel/Office 常见签名（不要求全部命中；任一命中即可）
        if sample.contains("urn:schemas-microsoft-com:office:excel") { return true }
        if sample.contains("microsoft excel") { return true }
        if sample.contains("mso-") { return true }

        // 兜底：明确的表格结构（Excel 复制单元格基本都会包含）
        if sample.contains("<table") && (sample.contains("<td") || sample.contains("<tr")) {
            return true
        }

        return false
    }

    nonisolated private static func rtfLooksLikeTable(_ rtfData: Data) -> Bool {
        let sample = String(decoding: rtfData.prefix(16 * 1024), as: UTF8.self).lowercased()
        // RTF 表格常见控制字：\trowd / \cell
        return sample.contains("\\trowd") || sample.contains("\\cell")
    }

    nonisolated private static func stringLooksLikeTabularData(_ string: String) -> Bool {
        // Excel/Sheets 复制单元格的 plain text 往往是 TSV（列用 tab，行用 \n）。
        // 注意：不要仅凭“多行”就判定为表格，否则可能误伤“复制图片 + 多行文本描述”的场景。
        return string.contains("\t")
    }

    // MARK: - Helper Methods

    private func extractPreferredPlainText(from pasteboard: NSPasteboard, richTextData: Data, type: ClipboardItemType) -> String {
        let extracted: String?
        switch type {
        case .rtf:
            extracted = Self.extractPlainTextFromRTF(richTextData)
        case .html:
            extracted = extractPlainTextFromHTML(richTextData)
        default:
            extracted = nil
        }
        return Self.preferredPlainText(candidate: pasteboard.string(forType: .string), extracted: extracted, type: type)
    }

    /// Chooses between the pasteboard `.string` and the text extracted from the rich payload.
    ///
    /// Prefer the pasteboard-provided `.string` when it is a faithful plain-text representation of the rich
    /// payload. Some apps provide `.string` that is already a lossy transformation (e.g. rich -> Markdown), which
    /// can corrupt TeX-heavy content; in those cases, fall back to the text extracted from the rich payload.
    nonisolated private static func preferredPlainText(candidate: String?, extracted: String?, type: ClipboardItemType) -> String {
        let candidate = candidate ?? ""
        if candidate.isEmpty {
            return extracted ?? ""
        }

        guard let extracted, !extracted.isEmpty else {
            return candidate
        }

        if Self.normalizeText(candidate) == Self.normalizeText(extracted) {
            return candidate
        }

        // Some producers place the authored Markdown in `text/plain` and its rendered copy in `text/html`.
        // Preserve that source representation when it is clearly Markdown and the HTML-derived text confirms
        // that both payloads describe the same content. The HTML payload itself remains the stored rich payload.
        if type == .html, Self.isClearlyStructuredMarkdown(candidate) {
            if Self.textRepresentationsAreRelated(candidate, extracted) {
                return candidate
            }
            return extracted
        }

        // If the extracted text is TeX-heavy and the pasteboard `.string` differs materially from it, prefer the
        // extracted version to avoid storing a transformed/Markdown-converted representation.
        if Self.containsTeXCommands(extracted) {
            return extracted
        }

        return candidate
    }

    /// Whether the text extracted from `htmlData` (or the pasteboard string) could carry TeX commands.
    /// `containsTeXCommands` needs a backslash or a dollar sign; when neither the raw HTML bytes (including
    /// numeric or named entities that could decode to them) nor the plain string contain one, the HTML
    /// import cannot change which representation is stored.
    nonisolated private static func mayContainTeXCharacters(htmlData: Data, string: String?) -> Bool {
        if let string, string.contains("\\") || string.contains("$") {
            return true
        }
        let backslash = UInt8(ascii: "\\"), dollar = UInt8(ascii: "$"), ampersand = UInt8(ascii: "&"), hash = UInt8(ascii: "#")
        var previous: UInt8 = 0
        for byte in htmlData {
            if byte == backslash || byte == dollar { return true }
            if previous == ampersand, byte == hash { return true }
            previous = byte
        }
        // Named entities for the same characters.
        if let text = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .utf16) {
            if text.range(of: "&dollar", options: .caseInsensitive) != nil || text.range(of: "&bsol", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }

    /// Text-representation extraction off the main thread. RTF import, normalization and the Markdown/TeX
    /// heuristics run here; the WebKit HTML import must run on the main thread and is requested only when
    /// it can change the stored text.
    nonisolated private static func makeTextRawData(
        rtfData: Data?,
        htmlData: Data?,
        string: String?,
        appBundleID: String?,
        parseHTMLOnMain: @MainActor @Sendable (Data) -> String?
    ) async -> RawClipboardData? {
        // 3. RTF
        if let rtfData {
            let rtfPlainText = Self.normalizeText(
                Self.preferredPlainText(candidate: string, extracted: Self.extractPlainTextFromRTF(rtfData), type: .rtf)
            )
            var plainText = rtfPlainText
            if let htmlData {
                // The HTML text can only win when the RTF text is empty or fragmented, or when TeX may be
                // involved (`shouldPreferRichPlainText`); otherwise the 0.3-0.7 s/MB HTML import is skipped.
                let htmlTextCanWin = rtfPlainText.isEmpty
                    || Self.isLikelyFragmentedCopyText(rtfPlainText)
                    || Self.mayContainTeXCharacters(htmlData: htmlData, string: string)
                if htmlTextCanWin {
                    let extracted = await parseHTMLOnMain(htmlData)
                    let htmlPlainText = Self.normalizeText(
                        Self.preferredPlainText(candidate: string, extracted: extracted, type: .html)
                    )
                    if Self.shouldPreferRichPlainText(htmlPlainText, over: rtfPlainText) {
                        plainText = htmlPlainText
                    }
                }
            }
            return RawClipboardData(
                type: .rtf,
                plainText: plainText,
                rawData: rtfData,
                appBundleID: appBundleID,
                sizeBytes: rtfData.count
            )
        }

        // 4. HTML
        if let htmlData {
            let candidate = string ?? ""
            // `preferredPlainText` returns the pasteboard string unless it is empty, is authored Markdown,
            // or the HTML text carries TeX; only those cases need the import.
            let needsImport = candidate.isEmpty
                || Self.isClearlyStructuredMarkdown(candidate)
                || Self.mayContainTeXCharacters(htmlData: htmlData, string: string)
            let plainText: String
            if needsImport {
                let extracted = await parseHTMLOnMain(htmlData)
                plainText = Self.normalizeText(Self.preferredPlainText(candidate: string, extracted: extracted, type: .html))
            } else {
                plainText = Self.normalizeText(candidate)
            }
            return RawClipboardData(
                type: .html,
                plainText: plainText,
                rawData: htmlData,
                appBundleID: appBundleID,
                sizeBytes: htmlData.count
            )
        }

        // 5. Plain text (最低优先级 - 作为兜底)
        if let string {
            let normalizedText = Self.normalizeText(string)
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

    nonisolated private static func isClearlyStructuredMarkdown(_ text: String) -> Bool {
        // This is intentionally stricter than preview eligibility. Clipboard MIME selection should only override
        // rich-text extraction for unambiguous source Markdown, not prose that happens to contain punctuation.
        let sample = text.count > 64_000 ? String(text.prefix(64_000)) : text
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)

        var score = 0
        var listItemCount = 0
        var blockquoteCount = 0
        var fenceCount = 0
        var sawTableRow = false
        var sawTableDelimiter = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenceCount += 1
            }
            if Self.isATXHeading(line) {
                score += 2
            }
            if Self.isMarkdownListItem(line) {
                listItemCount += 1
            }
            if line.hasPrefix("> ") {
                blockquoteCount += 1
            }
            if line.contains("|") {
                sawTableRow = true
                if Self.isMarkdownTableDelimiter(line) {
                    sawTableDelimiter = true
                }
            }
        }

        if fenceCount >= 2 { score += 2 }
        if listItemCount >= 2 { score += 2 } else if listItemCount == 1 { score += 1 }
        if blockquoteCount >= 2 { score += 2 } else if blockquoteCount == 1 { score += 1 }
        if sawTableRow && sawTableDelimiter { score += 2 }
        if Self.containsPairedMarkdownMarker("**", in: sample) || Self.containsPairedMarkdownMarker("__", in: sample) {
            score += 1
        }
        if Self.containsMarkdownLink(in: sample) { score += 2 }
        if Self.containsPairedMarkdownMarker("$$", in: sample)
            || (sample.contains("\\(") && sample.contains("\\)"))
            || (sample.contains("\\[") && sample.contains("\\]")) {
            score += 2
        }

        return score >= 2
    }

    nonisolated private static func isATXHeading(_ line: String) -> Bool {
        let markerCount = line.prefix { $0 == "#" }.count
        guard (1...6).contains(markerCount), line.count > markerCount else { return false }
        return line[line.index(line.startIndex, offsetBy: markerCount)].isWhitespace
    }

    nonisolated private static func isMarkdownListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }

        var index = line.startIndex
        var digitCount = 0
        while index < line.endIndex, line[index].isNumber, digitCount < 9 {
            digitCount += 1
            index = line.index(after: index)
        }
        guard digitCount > 0, index < line.endIndex, line[index] == "." else { return false }
        index = line.index(after: index)
        return index < line.endIndex && line[index].isWhitespace
    }

    nonisolated private static func isMarkdownTableDelimiter(_ line: String) -> Bool {
        let cells = line.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    nonisolated private static func containsPairedMarkdownMarker(_ marker: String, in text: String) -> Bool {
        guard let first = text.range(of: marker) else { return false }
        return text[first.upperBound...].range(of: marker) != nil
    }

    nonisolated private static func containsMarkdownLink(in text: String) -> Bool {
        guard let closeBracket = text.range(of: "](") else { return false }
        return text[..<closeBracket.lowerBound].contains("[")
            && text[closeBracket.upperBound...].contains(")")
    }

    nonisolated private static func textRepresentationsAreRelated(_ candidate: String, _ extracted: String) -> Bool {
        let candidateTokens = Self.comparisonTokens(in: candidate)
        let extractedTokens = Self.comparisonTokens(in: extracted)
        guard candidateTokens.count >= 2, extractedTokens.count >= 2 else { return false }

        var candidateCounts: [String: Int] = [:]
        candidateCounts.reserveCapacity(candidateTokens.count)
        for token in candidateTokens {
            candidateCounts[token, default: 0] += 1
        }

        var commonCount = 0
        for token in extractedTokens {
            guard let count = candidateCounts[token], count > 0 else { continue }
            commonCount += 1
            candidateCounts[token] = count - 1
        }

        let extractedCoverage = Double(commonCount) / Double(extractedTokens.count)
        let candidateCoverage = Double(commonCount) / Double(candidateTokens.count)
        return extractedCoverage >= 0.75 && candidateCoverage >= 0.65
    }

    nonisolated private static func comparisonTokens(in text: String) -> [String] {
        let bounded = text.count > 64_000 ? String(text.prefix(64_000)) : text
        let sample = Self.strippingInlineMarkdownDestinations(bounded)
        var tokens: [String] = []
        tokens.reserveCapacity(min(sample.count / 5, 8_192))
        var current = ""

        for character in sample.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    nonisolated private static func strippingInlineMarkdownDestinations(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "]", next < text.endIndex, text[next] == "(" {
                var cursor = text.index(after: next)
                var depth = 1
                var isEscaped = false

                while cursor < text.endIndex {
                    let character = text[cursor]
                    let after = text.index(after: cursor)
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "(" {
                        depth += 1
                    } else if character == ")" {
                        depth -= 1
                        if depth == 0 {
                            result.append("]")
                            index = after
                            break
                        }
                    }
                    cursor = after
                }

                if depth == 0 {
                    continue
                }
            }

            result.append(text[index])
            index = next
        }

        return result
    }

    nonisolated private static func containsTeXCommands(_ text: String) -> Bool {
        // Heuristic: detect common TeX signals so we can prefer an extracted rich payload representation
        // over a corrupted pasteboard `.string` (e.g. KaTeX/MathML selection from web pages).
        if !text.contains("\\") && !text.contains("$") {
            return false
        }

        var sawBackslash = false
        var dollarCount = 0
        for ch in text {
            if ch == "$" {
                dollarCount += 1
                if dollarCount >= 2 { return true }
            }

            if sawBackslash {
                if ch.isLetter { return true } // \frac, \varepsilon, ...
                if ch == "(" || ch == "[" || ch == ")" || ch == "]" { return true } // \( \) \[ \]
                sawBackslash = false
                continue
            }

            if ch == "\\" {
                sawBackslash = true
            }
        }

        return false
    }

    nonisolated private static func shouldPreferRichPlainText(_ candidate: String, over baseline: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if baseline.isEmpty { return true }

        if Self.containsTeXCommands(candidate), !Self.containsTeXCommands(baseline) {
            return true
        }

        if Self.isLikelyFragmentedCopyText(baseline), !Self.isLikelyFragmentedCopyText(candidate) {
            return true
        }

        return false
    }

    nonisolated private static func isLikelyFragmentedCopyText(_ text: String) -> Bool {
        // Typical symptom when copying KaTeX-rendered equations as plain text: a lot of 1-2 character lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 8 else { return false }

        var shortLineCount = 0
        for line in lines {
            if line.count <= 2 { shortLineCount += 1 }
        }

        return Double(shortLineCount) / Double(lines.count) >= 0.6
    }

    private func getFrontmostAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Normalize text for consistent hashing (v0.md 3.2: 去首尾空白、统一换行)
    nonisolated private static func normalizeText(_ text: String) -> String {
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

    nonisolated private static func extractPlainTextFromRTF(_ data: Data) -> String? {
        guard let attributedString = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }
        return attributedString.string
    }

    private func extractPlainTextFromHTML(_ data: Data) -> String? {
        if let html = Self.decodeHTMLDataToString(data),
           html.range(of: "application/x-tex", options: .caseInsensitive) != nil {
            let extracted = Self.extractMarkdownLikeTextFromKaTeXHTML(html)
            if !extracted.isEmpty {
                return extracted
            }
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html
        ]
        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return attributedString.string
    }

    nonisolated private static func decodeHTMLDataToString(_ data: Data) -> String? {
        // In practice pasteboard HTML is usually UTF-8, but some producers emit UTF-16.
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            .isoLatin1,
            .windowsCP1252
        ]

        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }

        return nil
    }

    nonisolated private static func extractMarkdownLikeTextFromKaTeXHTML(_ html: String) -> String {
        // Fast path: avoid work when there's no KaTeX marker.
        if !html.localizedCaseInsensitiveContains("katex") {
            return ""
        }

        var output = ""
        output.reserveCapacity(min(html.utf8.count, 16_384))

        var index = html.startIndex
        var inKaTeX = false
        var kaTeXSpanDepth = 0
        var kaTeXIsDisplay = false

        var inAnnotation = false
        var annotationIsDisplay = false
        var annotationBuffer = ""

        while index < html.endIndex {
            guard let tagStart = html[index...].firstIndex(of: "<") else {
                let tail = String(html[index...])
                Self.appendHTMLText(tail, to: &output, inKaTeX: inKaTeX, inAnnotation: &inAnnotation, annotationBuffer: &annotationBuffer)
                break
            }

            let textSegment = String(html[index..<tagStart])
            Self.appendHTMLText(textSegment, to: &output, inKaTeX: inKaTeX, inAnnotation: &inAnnotation, annotationBuffer: &annotationBuffer)

            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else { break }
            let rawTag = String(html[html.index(after: tagStart)..<tagEnd])
            index = html.index(after: tagEnd)

            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.isEmpty { continue }
            if tag.hasPrefix("!--") { continue }

            let isClosing = tag.hasPrefix("/")
            let tagBody = isClosing ? tag.dropFirst() : Substring(tag)
            let tagName = tagBody
                .prefix { !$0.isWhitespace && $0 != "/" }
                .lowercased()

            if tagName.isEmpty { continue }

            if inAnnotation {
                if isClosing, tagName == "annotation" {
                    let tex = Self.decodeHTMLEntities(annotationBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                    annotationBuffer = ""
                    inAnnotation = false

                    if !tex.isEmpty {
                        if annotationIsDisplay {
                            Self.appendNewlines(1, to: &output)
                            output.append("$$\n")
                            output.append(tex)
                            output.append("\n$$")
                            Self.appendNewlines(1, to: &output)
                        } else {
                            output.append("$")
                            output.append(tex)
                            output.append("$")
                        }
                    }
                }
                continue
            }

            switch tagName {
            case "br":
                Self.appendNewlines(1, to: &output)
            case "p", "div", "section", "article":
                if isClosing {
                    Self.appendNewlines(2, to: &output)
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if isClosing {
                    Self.appendNewlines(2, to: &output)
                } else if let level = Int(tagName.dropFirst()) {
                    Self.appendNewlines(output.isEmpty ? 0 : 2, to: &output)
                    output.append(String(repeating: "#", count: level))
                    output.append(" ")
                }
            case "li":
                if isClosing {
                    Self.appendNewlines(1, to: &output)
                } else {
                    Self.appendNewlines(output.isEmpty ? 0 : 1, to: &output)
                    output.append("- ")
                }
            case "annotation":
                if !isClosing,
                   Self.attribute(named: "encoding", in: tag)?.lowercased() == "application/x-tex" {
                    inAnnotation = true
                    annotationIsDisplay = kaTeXIsDisplay
                    annotationBuffer = ""
                }
            case "span":
                if isClosing {
                    if inKaTeX {
                        kaTeXSpanDepth -= 1
                        if kaTeXSpanDepth <= 0 {
                            inKaTeX = false
                            kaTeXSpanDepth = 0
                            kaTeXIsDisplay = false
                        }
                    }
                } else {
                    if inKaTeX {
                        kaTeXSpanDepth += 1
                    } else if let classAttr = Self.attribute(named: "class", in: tag),
                              classAttr.localizedCaseInsensitiveContains("katex") {
                        inKaTeX = true
                        kaTeXSpanDepth = 1
                        kaTeXIsDisplay = classAttr.localizedCaseInsensitiveContains("katex-display")
                    }
                }
            default:
                break
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func appendHTMLText(
        _ text: String,
        to output: inout String,
        inKaTeX: Bool,
        inAnnotation: inout Bool,
        annotationBuffer: inout String
    ) {
        guard !text.isEmpty else { return }
        if inAnnotation {
            annotationBuffer.append(text)
            return
        }
        if inKaTeX {
            return
        }

        let decoded = Self.decodeHTMLEntities(text)
        for ch in decoded {
            if ch.isWhitespace || ch.isNewline {
                if output.isEmpty { continue }
                if output.last == " " || output.last == "\n" { continue }
                output.append(" ")
            } else {
                output.append(ch)
            }
        }
    }

    nonisolated private static func appendNewlines(_ count: Int, to output: inout String) {
        guard count > 0 else { return }
        var trimmed = output
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        output = trimmed
        if output.isEmpty {
            output.append(String(repeating: "\n", count: count))
            return
        }

        let existingNewlines = output.reversed().prefix { $0 == "\n" }.count
        let needed = max(0, count - existingNewlines)
        if needed > 0 {
            output.append(String(repeating: "\n", count: needed))
        }
    }

    nonisolated private static func attribute(named name: String, in tag: String) -> String? {
        // Extremely small attribute parser: looks for name="..." or name='...'.
        // Tag is the raw content inside "<" and ">".
        let needle = "\(name.lowercased())="
        guard let range = tag.range(of: needle, options: [.caseInsensitive]) else { return nil }

        var i = range.upperBound
        while i < tag.endIndex, tag[i].isWhitespace {
            i = tag.index(after: i)
        }
        guard i < tag.endIndex else { return nil }

        let quote = tag[i]
        if quote == "\"" || quote == "'" {
            let start = tag.index(after: i)
            guard let end = tag[start...].firstIndex(of: quote) else { return nil }
            return String(tag[start..<end])
        }

        // Unquoted value: read until whitespace.
        let start = i
        var end = start
        while end < tag.endIndex, !tag[end].isWhitespace {
            end = tag.index(after: end)
        }
        return String(tag[start..<end])
    }

    nonisolated private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var output = ""
        output.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch != "&" {
                output.append(ch)
                index = text.index(after: index)
                continue
            }

            guard let semi = text[index...].firstIndex(of: ";") else {
                output.append(ch)
                index = text.index(after: index)
                continue
            }

            let entity = String(text[text.index(after: index)..<semi])
            if let decoded = Self.decodeHTMLEntity(entity) {
                output.append(decoded)
                index = text.index(after: semi)
                continue
            }

            output.append("&")
            index = text.index(after: index)
        }

        return output
    }

    nonisolated private static func decodeHTMLEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "#39", "apos": return "'"
        case "nbsp": return " "
        default:
            break
        }

        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            let hex = entity.dropFirst(2)
            if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
                return String(Character(scalar))
            }
            return nil
        }

        if entity.hasPrefix("#") {
            let dec = entity.dropFirst()
            if let value = UInt32(dec, radix: 10), let scalar = UnicodeScalar(value) {
                return String(Character(scalar))
            }
            return nil
        }

        return nil
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
    private func extractImageDataForIngest(
        from pasteboard: NSPasteboard,
        candidateFileURL: URL? = nil
    ) -> (data: Data, wasTIFF: Bool)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, false)
        }

        if let tiffData = pasteboard.data(forType: .tiff) {
            return (tiffData, true)
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation,
           let pngData = Self.convertTIFFToPNG(tiffData) {
            return (pngData, false)
        }

        if let candidateFileURL,
           let pngData = Self.loadImageFileDataAsPNG(candidateFileURL) {
            return (pngData, false)
        }

        return nil
    }

    /// 从剪贴板提取图片数据，优先 PNG，如果只有 TIFF 则转换为 PNG
    private func extractOptimalImageData(
        from pasteboard: NSPasteboard,
        candidateFileURL: URL? = nil
    ) -> (data: Data, wasTIFF: Bool)? {
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

        if let image = NSImage(pasteboard: pasteboard),
           let tiffData = image.tiffRepresentation,
           let pngData = Self.convertTIFFToPNG(tiffData) {
            return (pngData, false)
        }

        if let candidateFileURL,
           let pngData = Self.loadImageFileDataAsPNG(candidateFileURL) {
            return (pngData, false)
        }

        return nil
    }
}
