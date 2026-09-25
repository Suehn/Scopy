import AppKit
import Foundation

/// Polls the system pasteboard, records Scopy's own writes as the capture baseline, and feeds
/// every capture through one serial ingest FIFO into `contentStream`. Reading, type decisions,
/// text extraction, the durable spool, and envelope processing live in `Services/Capture`.
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

    /// One pasteboard change as read on the main actor. Hashing happens later: inline for small
    /// text, in envelope processing off the main actor for images and large payloads.
    struct RawClipboardData: Sendable {
        let type: ClipboardItemType
        let plainText: String
        let rawData: Data?
        let appBundleID: String?
        let sizeBytes: Int
        let precomputedHash: String?  // A hash decided at read time overrides the content-hash policy.
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

    /// One entry of the serial ingest FIFO. Small captures are ready immediately; large ones
    /// are durable envelopes processed off the main actor in queue order.
    private enum IngestJob: Sendable {
        case ready(ClipboardContent)
        case envelope(URL, sessionID: UInt64)
    }

    /// Extracted content whose durable envelope could not be written yet. It is retried from
    /// memory on later polls instead of rereading or dropping the pasteboard.
    private struct PendingPersistRetry {
        let rawData: RawClipboardData
        let changeCount: Int
        let ownWriteGeneration: UInt64
        let sessionID: UInt64
    }

    public struct TerminalIngestAcknowledgement: Sendable {
        public let ingestID: UUID
        let markerURL: URL
        let payloadFileName: String?
    }

    public enum IngestAcknowledgementOutcome: Sendable {
        case terminal(TerminalIngestAcknowledgement)
        case rejected
    }

    // MARK: - Properties

    private let pasteboard: NSPasteboard
    private let writer: PasteboardWriter

    nonisolated private let timerBox: TimerBox

    /// The last changeCount that was handled: captured, found empty, or written by Scopy itself.
    private var handledChangeCount: Int = 0

    /// Incremented by every Scopy pasteboard write, so a capture that suspended across one does
    /// not move the baseline back to the pre-write changeCount.
    private var ownWriteGeneration: UInt64 = 0

    private var isMonitoring = false

    private var monitoringSessionID: UInt64 = 0

    private var isCheckingClipboard = false

    private var pendingPersistRetry: PendingPersistRetry?

    /// Serial, bounded FIFO shared by small and large captures, so history order follows
    /// capture order and a full queue applies backpressure to polling.
    private let ingestJobs: AsyncBoundedQueue<IngestJob>

    private var activeEnvelopeWork: Task<IngestEnvelopeProcessor.Outcome, Never>?

    private var replayTask: Task<Void, Never>?

    private var trackedPendingEnvelopePaths = Set<String>()

    /// Test injection: delay applied before each envelope is processed.
    var ingestProcessingDelay: Duration = .zero

    private let contentQueue: AsyncBoundedQueue<ClipboardContent>

    public let contentStream: AsyncStream<ClipboardContent>

    private let ingestSpoolDirectory: URL

    public private(set) var pollingInterval: TimeInterval = 0.5

    // MARK: - Lifecycle

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
        self.writer = PasteboardWriter(pasteboard: pasteboard)
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
        let jobs = AsyncBoundedQueue<IngestJob>(capacity: ScopyThresholds.ingestMaxPendingItems)
        self.ingestJobs = jobs
        self.handledChangeCount = pasteboard.changeCount
        // One worker drains the FIFO for the monitor's lifetime; deinit finishes the queue.
        Task { [weak self] in
            while let job = await jobs.dequeue() {
                guard let self else { return }
                await self.process(job)
            }
        }
    }

    nonisolated static func defaultLegacyIngestSpoolDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Scopy", isDirectory: true)
            .appendingPathComponent("ingest", isDirectory: true)
    }

    /// Performs potentially large legacy copies and artifact enumeration outside the monitor's
    /// main-actor lifecycle in production. The public initializer keeps a synchronous fallback for
    /// standalone callers that cannot participate in ClipboardBackend startup orchestration.
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
            IngestSpool.migrateLegacyPendingEnvelopes(from: legacyDirectory, to: ingestDirectory)
        }
        IngestSpool.cleanupStaleControlledArtifacts(in: ingestDirectory)
    }

    deinit {
        Task { [contentQueue, ingestJobs] in
            await ingestJobs.finish()
            await contentQueue.finish()
        }

        // Ensure the RunLoop timer is invalidated even if `stopMonitoring()` was not called.
        if let timer = timerBox.take() {
            let sendableTimer = SendableTimer(timer: timer)
            DispatchQueue.main.async {
                sendableTimer.timer.invalidate()
            }
        }
    }

    public func startMonitoring() {
        // The timer is added to the main run loop; started elsewhere it would never fire.
        assert(Thread.isMainThread, "startMonitoring must be called on main thread")

        guard !isMonitoring else { return }
        isMonitoring = true
        monitoringSessionID &+= 1
        handledChangeCount = pasteboard.changeCount
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
        // Envelope jobs queued by this session are skipped by the worker; their envelopes stay
        // on disk and replay on the next start.
        activeEnvelopeWork?.cancel()
        replayTask?.cancel()
        replayTask = nil
        trackedPendingEnvelopePaths.removeAll()
        publishIngestSnapshot()
    }

    public func setPollingInterval(_ interval: TimeInterval) {
        pollingInterval = max(0.1, min(5.0, interval)) // Clamp between 100ms and 5s
        if isMonitoring {
            installMonitoringTimer()
        }
    }

    // MARK: - Polling And Baseline

    func checkClipboard() async {
        guard isMonitoring else { return }
        guard !isCheckingClipboard else { return }
        let sessionID = monitoringSessionID
        isCheckingClipboard = true
        defer { isCheckingClipboard = false }

        if let retry = pendingPersistRetry {
            guard await submitDurableCapture(retry.rawData, logFailure: false) else { return }
            pendingPersistRetry = nil
            settle(retry.changeCount, ownWriteGeneration: retry.ownWriteGeneration, sessionID: retry.sessionID)
            guard isMonitoring, monitoringSessionID == sessionID else { return }
        }

        let currentChangeCount = pasteboard.changeCount
        let previousChangeCount = handledChangeCount

        guard currentChangeCount != previousChangeCount else { return }
        let generation = ownWriteGeneration
        let delta = currentChangeCount - previousChangeCount
        if delta > 1 {
            ScopyLog.monitor.debug("Pasteboard changeCount jumped by \(delta) (prev=\(previousChangeCount), current=\(currentChangeCount))")
            Task {
                await ClipboardIngestMetrics.shared.recordChangeDelta(delta)
            }
        }

        // Read this change's representations on the main actor.
        let extractStart = ProcessInfo.processInfo.systemUptime
        let rawData: RawClipboardData
        switch await PasteboardReadSession(pasteboard: pasteboard, changeCount: currentChangeCount).read() {
        case .changedDuringRead:
            return
        case .nothing:
            // Empty or unsupported content is evaluated once instead of being reread every poll.
            settle(currentChangeCount, ownWriteGeneration: generation, sessionID: sessionID)
            return
        case .content(let extracted):
            rawData = extracted
        }
        let extractMs = (ProcessInfo.processInfo.systemUptime - extractStart) * 1000
        let extractSummary = "\(rawData.type.rawValue) \(rawData.sizeBytes) bytes, main-thread wait \(Int(extractMs)) ms"
        ScopyLog.monitor.debug("Capture extract \(extractSummary, privacy: .public)")

        // Skip empty content
        guard !rawData.plainText.isEmpty || (rawData.rawData != nil && !rawData.rawData!.isEmpty) else {
            settle(currentChangeCount, ownWriteGeneration: generation, sessionID: sessionID)
            return
        }

        // Images always take the durable envelope path so their SHA-256 runs off the main
        // actor; other content does so from the durable-envelope size up. Everything smaller
        // is hashed inline and queued directly.
        if rawData.type == .image || rawData.sizeBytes >= ScopyThresholds.ingestDurableEnvelopeBytes {
            guard await submitDurableCapture(rawData, logFailure: true) else {
                pendingPersistRetry = PendingPersistRetry(
                    rawData: rawData,
                    changeCount: currentChangeCount,
                    ownWriteGeneration: generation,
                    sessionID: sessionID
                )
                return
            }
            settle(currentChangeCount, ownWriteGeneration: generation, sessionID: sessionID)
            return
        }

        // Small non-image content: hash inline, then queue behind any earlier large capture.
        let hash = CapturePolicy.contentHash(
            type: rawData.type,
            plainText: rawData.plainText,
            payloadData: rawData.rawData,
            precomputedHash: rawData.precomputedHash
        )
        let content = ClipboardContent(
            type: rawData.type,
            plainText: rawData.plainText,
            payload: rawData.rawData.map(ClipboardContent.Payload.data) ?? .none,
            appBundleID: rawData.appBundleID,
            contentHash: hash,
            sizeBytes: rawData.sizeBytes
        )
        await replayTask?.value
        await ingestJobs.enqueue(.ready(content))
        settle(currentChangeCount, ownWriteGeneration: generation, sessionID: sessionID)
    }

    /// Advances the baseline to a handled changeCount unless a Scopy write or a stop/start
    /// happened meanwhile; those already own a newer baseline that must not move back.
    private func settle(_ changeCount: Int, ownWriteGeneration generation: UInt64, sessionID: UInt64) {
        guard sessionID == monitoringSessionID, generation == ownWriteGeneration else { return }
        handledChangeCount = changeCount
    }

    /// Called once per Scopy pasteboard write after its representations are written, whether or
    /// not all of them succeeded, so polling never recaptures Scopy's own write.
    private func recordOwnWrite() {
        handledChangeCount = pasteboard.changeCount
        ownWriteGeneration &+= 1
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
        timer.tolerance = pollingInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        timerBox.set(timer)
    }

    // MARK: - Ingest Orchestration

    /// Writes the durable envelope off the main actor, then queues it behind earlier captures.
    /// Returns false when the envelope could not be written, so the caller can retry from memory.
    private func submitDurableCapture(_ rawData: RawClipboardData, logFailure: Bool) async -> Bool {
        let envelopeURL: URL
        let ingestDirectory = ingestSpoolDirectory
        do {
            envelopeURL = try await Task.detached(priority: .userInitiated) {
                try IngestSpool.persistPendingEnvelope(for: rawData, in: ingestDirectory)
            }.value
        } catch {
            if logFailure {
                ScopyLog.monitor.error(
                    "Failed to persist ingest envelope; retrying from memory: \(error.localizedDescription, privacy: .private)"
                )
            }
            return false
        }

        await ClipboardIngestMetrics.shared.recordPersistedEnvelope()

        // A completed envelope is durable. If monitoring stopped while the write was in flight,
        // leave it on disk for the next replay instead of queueing it in a stopped session.
        guard isMonitoring else { return true }
        guard trackedPendingEnvelopePaths.insert(envelopeURL.path).inserted else { return true }
        if trackedPendingEnvelopePaths.count > ScopyThresholds.ingestMaxPendingItems {
            Task {
                await ClipboardIngestMetrics.shared.recordSoftLimitHit()
            }
        }
        publishIngestSnapshot()

        let sessionID = monitoringSessionID
        await replayTask?.value
        await ingestJobs.enqueue(.envelope(envelopeURL, sessionID: sessionID))
        return true
    }

    private func process(_ job: IngestJob) async {
        switch job {
        case .ready(let content):
            await contentQueue.enqueue(content)
        case .envelope(let envelopeURL, let sessionID):
            // Jobs from a stopped session are skipped; their envelopes replay on the next start.
            guard isMonitoring, monitoringSessionID == sessionID else { return }

            let ingestDirectory = ingestSpoolDirectory
            let delay = ingestProcessingDelay
            let work = Task.detached(priority: .userInitiated) {
                await IngestEnvelopeProcessor.buildContent(from: envelopeURL, ingestDirectory: ingestDirectory, delay: delay)
            }
            activeEnvelopeWork = work
            publishIngestSnapshot()
            let result = await work.value
            activeEnvelopeWork = nil
            publishIngestSnapshot()

            switch result {
            case .cancelled:
                return
            case .invalid:
                discardIngestEnvelope(at: envelopeURL)
            case .content(let content):
                guard isMonitoring, monitoringSessionID == sessionID else {
                    IngestEnvelopeProcessor.cleanupPayloadIfNeeded(content.payload, ownership: content.fileOwnership)
                    return
                }
                await contentQueue.enqueue(content)
            }
        }
    }

    private func replayPendingLargeContentFromDisk() {
        let persisted = IngestSpool.discoverPendingEnvelopeURLs(in: ingestSpoolDirectory)
        let replayed = persisted.filter { trackedPendingEnvelopePaths.insert($0.path).inserted }
        guard !replayed.isEmpty else { return }
        publishIngestSnapshot()

        // New captures wait for this task, so replayed envelopes stay ahead of them in the FIFO.
        let sessionID = monitoringSessionID
        let jobs = ingestJobs
        replayTask = Task {
            for envelopeURL in replayed {
                await jobs.enqueue(.envelope(envelopeURL, sessionID: sessionID))
            }
        }
        Task {
            await ClipboardIngestMetrics.shared.recordReplay(count: replayed.count)
        }
    }

    private func discardIngestEnvelope(at url: URL) {
        switch acknowledgeIngestEnvelope(at: url) {
        case .terminal(let acknowledgement):
            completeTerminalIngestAcknowledgement(acknowledgement)
        case .rejected:
            IngestSpool.quarantinePendingEnvelope(at: url, ingestDirectory: ingestSpoolDirectory)
            trackedPendingEnvelopePaths.remove(url.path)
            publishIngestSnapshot()
        }
    }

    private func publishIngestSnapshot() {
        let activeCount = activeEnvelopeWork == nil ? 0 : 1
        let persistedCount = trackedPendingEnvelopePaths.count
        let pendingCount = max(0, persistedCount - activeCount)
        Task {
            await ClipboardIngestMetrics.shared.updateQueueSnapshot(
                pendingCount: pendingCount,
                activeCount: activeCount,
                persistedCount: persistedCount
            )
        }
    }

    @discardableResult
    public func acknowledgeIngestEnvelope(at url: URL) -> IngestAcknowledgementOutcome {
        guard let acknowledgement = IngestSpool.transitionEnvelopeToTerminal(
            at: url,
            ingestDirectory: ingestSpoolDirectory
        ) else {
            return .rejected
        }

        trackedPendingEnvelopePaths.remove(url.path)
        publishIngestSnapshot()
        Task {
            await ClipboardIngestMetrics.shared.recordAcknowledgedEnvelope()
        }
        return .terminal(acknowledgement)
    }

    public func pendingTerminalIngestAcknowledgements(
        limit: Int = 256,
        excluding excludedIDs: Set<UUID> = []
    ) -> [TerminalIngestAcknowledgement] {
        IngestSpool.discoverTerminalAcknowledgements(
            in: ingestSpoolDirectory,
            limit: max(0, limit),
            excluding: excludedIDs
        )
    }

    @discardableResult
    public func completeTerminalIngestAcknowledgement(
        _ acknowledgement: TerminalIngestAcknowledgement
    ) -> Bool {
        guard IngestSpool.validateTerminalAcknowledgement(
            acknowledgement,
            ingestDirectory: ingestSpoolDirectory
        ) else {
            return false
        }
        return IngestSpool.cleanupTerminalAcknowledgement(
            acknowledgement,
            ingestDirectory: ingestSpoolDirectory
        )
    }

    // MARK: - Pasteboard Writes

    /// Every write goes through PasteboardWriter and is then recorded as the capture baseline,
    /// so polling never recaptures Scopy's own write.
    public func copyToClipboard(text: String) throws {
        defer { recordOwnWrite() }
        try writer.write(text: text)
    }

    public func copyToClipboard(
        data: Data,
        type: NSPasteboard.PasteboardType,
        imageWriteMode: ImagePasteboardWriteMode = .standard
    ) throws {
        defer { recordOwnWrite() }
        try writer.write(data: data, type: type, imageWriteMode: imageWriteMode)
    }

    public func copyToClipboard(
        imageData data: Data,
        fileURL: URL,
        imageWriteMode: ImagePasteboardWriteMode = .standard
    ) throws {
        defer { recordOwnWrite() }
        try writer.write(imageData: data, fileURL: fileURL, imageWriteMode: imageWriteMode)
    }

    public func copyToClipboard(text: String, data: Data, type: NSPasteboard.PasteboardType) throws {
        defer { recordOwnWrite() }
        try writer.write(text: text, data: data, type: type)
    }

    public func copyToClipboard(fileURLs: [URL]) throws {
        defer { recordOwnWrite() }
        try writer.write(fileURLs: fileURLs)
    }
}
