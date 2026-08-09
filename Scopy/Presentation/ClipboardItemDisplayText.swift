import Foundation
import ScopyKit
import ScopyUISupport

/// A deterministic FIFO cache that always admits the newest key while keeping storage bounded.
/// Main-actor presentation caches own instances of this value; it has no internal synchronization.
struct BoundedPresentationCache<Key: Hashable, Value> {
    private let capacity: Int
    private var values: [Key: Value] = [:]
    private var insertionOrder: [Key] = []
    private var firstLiveOrderIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        values.reserveCapacity(capacity)
        insertionOrder.reserveCapacity(capacity)
    }

    var count: Int {
        values.count
    }

    subscript(key: Key) -> Value? {
        values[key]
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        if values[key] != nil {
            values[key] = value
            return
        }

        evictOldestIfFull()
        values[key] = value
        insertionOrder.append(key)
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        firstLiveOrderIndex = 0
    }

    private mutating func evictOldestIfFull() {
        while values.count >= capacity, firstLiveOrderIndex < insertionOrder.count {
            let oldestKey = insertionOrder[firstLiveOrderIndex]
            firstLiveOrderIndex += 1
            if values.removeValue(forKey: oldestKey) != nil {
                break
            }
        }

        if firstLiveOrderIndex >= capacity,
           firstLiveOrderIndex * 2 >= insertionOrder.count {
            insertionOrder.removeFirst(firstLiveOrderIndex)
            firstLiveOrderIndex = 0
        }
    }
}

final class PresentationPrewarmCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Presentation-only helpers for deriving display strings from `ClipboardItemDTO`.
///
/// Domain model should not carry UI-specific derived fields (e.g. title/metadata).
/// This cache keeps UI rendering cheap without bloating the DTO.
@MainActor
final class ClipboardItemDisplayText {
    static let shared = ClipboardItemDisplayText()

    private struct TitleCacheKey: Hashable, Sendable {
        let revision: ClipboardItemContentRevision
    }

    private struct MetadataCacheKey: Hashable, Sendable {
        let revision: ClipboardItemContentRevision
        let note: String?
    }

    private struct PrewarmSnapshot: Sendable {
        let type: ClipboardItemType
        let revision: ClipboardItemContentRevision
        let plainText: String
        let note: String?
        let sizeBytes: Int
        let fileSizeBytes: Int?
    }

    private struct PrewarmEntry: Sendable {
        let titleKey: TitleCacheKey
        let metadataKey: MetadataCacheKey
        let title: String
        let metadata: CachedMetadata
    }

    private struct PrewarmIdentity: Hashable, Sendable {
        let revision: ClipboardItemContentRevision
        let note: String?
    }

    private struct PrewarmWork: Sendable {
        let token: UInt64
        let cacheGeneration: UInt64
        let cancellation: PresentationPrewarmCancellationFlag
        let identities: Set<PrewarmIdentity>
        let snapshots: [PrewarmSnapshot]
    }

    private struct DisplayTextPair: Sendable {
        let title: String
        let metadata: String
        let searchMetadataPrefix: String?
    }

    private struct CachedMetadata: Sendable {
        let text: String
        let searchMetadataPrefix: String?
    }

    private static let defaultCacheLimit = 20_000
    private static let defaultPrewarmBatchLimit = 1_024

    private var prewarmBatchLimit: Int
    private var titleCache: BoundedPresentationCache<TitleCacheKey, String>
    private var metadataCache: BoundedPresentationCache<MetadataCacheKey, CachedMetadata>
    private var cacheGeneration: UInt64 = 0
    private var prewarmToken: UInt64 = 0
    private var prewarmWorkerTask: Task<Void, Never>?
    private var pendingPrewarmWork: PrewarmWork?
    private var activePrewarmToken: UInt64?
    private var activePrewarmCancellation: PresentationPrewarmCancellationFlag?
    private var activePrewarmIdentities: Set<PrewarmIdentity> = []

    private init() {
        prewarmBatchLimit = Self.defaultPrewarmBatchLimit
        titleCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        metadataCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
    }

    func title(for item: ClipboardItemDTO) -> String {
        let titleKey = makeTitleCacheKey(for: item)
        if let cached = titleCache[titleKey] { return cached }

        let pair = computeDisplayTextPair(for: item, metricName: "text.title_ms")
        storeDisplayTextPair(pair, titleKey: titleKey, metadataKey: makeMetadataCacheKey(for: item))
        return pair.title
    }

    func metadata(for item: ClipboardItemDTO) -> String {
        let metadataKey = makeMetadataCacheKey(for: item)
        if let cached = metadataCache[metadataKey] { return cached.text }

        let pair = computeDisplayTextPair(for: item, metricName: "text.metadata_ms")
        storeDisplayTextPair(pair, titleKey: makeTitleCacheKey(for: item), metadataKey: metadataKey)
        return pair.metadata
    }

    func displayTexts(
        for item: ClipboardItemDTO
    ) -> (title: String, metadata: String, searchMetadataPrefix: String?) {
        let titleKey = makeTitleCacheKey(for: item)
        let metadataKey = makeMetadataCacheKey(for: item)
        if let title = titleCache[titleKey],
           let metadata = metadataCache[metadataKey] {
            return (title, metadata.text, metadata.searchMetadataPrefix)
        }

        let pair = computeDisplayTextPair(for: item, metricName: "text.metadata_ms")
        storeDisplayTextPair(pair, titleKey: titleKey, metadataKey: metadataKey)
        return (pair.title, pair.metadata, pair.searchMetadataPrefix)
    }

    @discardableResult
    func prewarm(items: [ClipboardItemDTO]) -> Task<Void, Never>? {
        guard !items.isEmpty else {
            cancelSupersededPrewarm(pendingReplacement: nil)
            return nil
        }

        var identities: Set<PrewarmIdentity> = []
        var snapshots: [PrewarmSnapshot] = []
        snapshots.reserveCapacity(min(items.count, prewarmBatchLimit))

        for item in items where snapshots.count < prewarmBatchLimit {
            let revision = ClipboardItemContentRevision(item: item)
            let identity = PrewarmIdentity(revision: revision, note: item.note)
            guard identities.insert(identity).inserted else { continue }

            let titleKey = TitleCacheKey(revision: revision)
            let metadataKey = MetadataCacheKey(revision: revision, note: item.note)
            guard titleCache[titleKey] == nil || metadataCache[metadataKey] == nil else {
                identities.remove(identity)
                continue
            }

            snapshots.append(
                PrewarmSnapshot(
                    type: item.type,
                    revision: revision,
                    plainText: item.plainText,
                    note: item.note,
                    sizeBytes: item.sizeBytes,
                    fileSizeBytes: item.fileSizeBytes
                )
            )
        }
        guard !snapshots.isEmpty else {
            cancelSupersededPrewarm(pendingReplacement: nil)
            return nil
        }

        if activePrewarmIdentities == identities,
           activePrewarmCancellation?.isCancelled == false {
            pendingPrewarmWork?.cancellation.cancel()
            pendingPrewarmWork = nil
            return nil
        }
        if pendingPrewarmWork?.identities == identities {
            return nil
        }

        prewarmToken &+= 1
        let work = PrewarmWork(
            token: prewarmToken,
            cacheGeneration: cacheGeneration,
            cancellation: PresentationPrewarmCancellationFlag(),
            identities: identities,
            snapshots: snapshots
        )
        cancelSupersededPrewarm(pendingReplacement: work)

        if let prewarmWorkerTask {
            return prewarmWorkerTask
        }

        let task = Task.detached(priority: .utility) {
            while let work = await MainActor.run(body: {
                ClipboardItemDisplayText.shared.takeNextPrewarmWork()
            }) {
                var entries: [PrewarmEntry] = []
                entries.reserveCapacity(work.snapshots.count)
                for snapshot in work.snapshots {
                    guard !work.cancellation.isCancelled else { break }
                    let pair = Self.computeDisplayTextPair(
                        type: snapshot.type,
                        plainText: snapshot.plainText,
                        note: snapshot.note,
                        sizeBytes: snapshot.sizeBytes,
                        fileSizeBytes: snapshot.fileSizeBytes
                    )
                    guard !work.cancellation.isCancelled else { break }
                    entries.append(
                        PrewarmEntry(
                            titleKey: TitleCacheKey(revision: snapshot.revision),
                            metadataKey: MetadataCacheKey(
                                revision: snapshot.revision,
                                note: snapshot.note
                            ),
                            title: pair.title,
                            metadata: CachedMetadata(
                                text: pair.metadata,
                                searchMetadataPrefix: pair.searchMetadataPrefix
                            )
                        )
                    )
                }

                let preparedEntries = entries
                await MainActor.run {
                    ClipboardItemDisplayText.shared.completePrewarm(
                        work: work,
                        entries: preparedEntries
                    )
                }
            }
        }
        prewarmWorkerTask = task

        return task
    }

    func cachedTitle(for item: ClipboardItemDTO) -> String? {
        titleCache[makeTitleCacheKey(for: item)]
    }

    func cachedMetadata(for item: ClipboardItemDTO) -> String? {
        metadataCache[makeMetadataCacheKey(for: item)]?.text
    }

    func clearCaches() {
        cacheGeneration &+= 1
        prewarmToken &+= 1
        activePrewarmCancellation?.cancel()
        pendingPrewarmWork?.cancellation.cancel()
        pendingPrewarmWork = nil
        activePrewarmToken = nil
        activePrewarmCancellation = nil
        activePrewarmIdentities.removeAll(keepingCapacity: true)
        titleCache.removeAll()
        metadataCache.removeAll()
    }

    private func makeTitleCacheKey(for item: ClipboardItemDTO) -> TitleCacheKey {
        TitleCacheKey(revision: ClipboardItemContentRevision(item: item))
    }

    private func makeMetadataCacheKey(for item: ClipboardItemDTO) -> MetadataCacheKey {
        MetadataCacheKey(
            revision: ClipboardItemContentRevision(item: item),
            note: item.note
        )
    }

    private func storePrewarmEntries(_ entries: [PrewarmEntry]) {
        for entry in entries {
            titleCache.insert(entry.title, forKey: entry.titleKey)
            metadataCache.insert(entry.metadata, forKey: entry.metadataKey)
        }
    }

    private func storeDisplayTextPair(_ pair: DisplayTextPair, titleKey: TitleCacheKey, metadataKey: MetadataCacheKey) {
        titleCache.insert(pair.title, forKey: titleKey)
        metadataCache.insert(
            CachedMetadata(
                text: pair.metadata,
                searchMetadataPrefix: pair.searchMetadataPrefix
            ),
            forKey: metadataKey
        )
    }

    private func cancelSupersededPrewarm(pendingReplacement: PrewarmWork?) {
        activePrewarmCancellation?.cancel()
        pendingPrewarmWork?.cancellation.cancel()
        pendingPrewarmWork = pendingReplacement
    }

    private func takeNextPrewarmWork() -> PrewarmWork? {
        guard let work = pendingPrewarmWork else {
            prewarmWorkerTask = nil
            return nil
        }
        pendingPrewarmWork = nil
        activePrewarmToken = work.token
        activePrewarmCancellation = work.cancellation
        activePrewarmIdentities = work.identities
        return work
    }

    private func completePrewarm(work: PrewarmWork, entries: [PrewarmEntry]) {
        guard activePrewarmToken == work.token else { return }
        activePrewarmToken = nil
        activePrewarmCancellation = nil
        activePrewarmIdentities.removeAll(keepingCapacity: true)

        guard !work.cancellation.isCancelled,
              cacheGeneration == work.cacheGeneration else { return }
        storePrewarmEntries(entries)
    }

    func configureCacheCapacityForTesting(_ capacity: Int) {
        precondition(capacity > 0)
        clearCaches()
        prewarmBatchLimit = capacity
        titleCache = BoundedPresentationCache(capacity: capacity)
        metadataCache = BoundedPresentationCache(capacity: capacity)
    }

    func restoreDefaultCacheCapacityForTesting() {
        clearCaches()
        prewarmBatchLimit = Self.defaultPrewarmBatchLimit
        titleCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        metadataCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
    }

    var cacheEntryCountsForTesting: (title: Int, metadata: Int) {
        (titleCache.count, metadataCache.count)
    }

    var prewarmInFlightCountForTesting: Int {
        activePrewarmIdentities.count + (pendingPrewarmWork?.identities.count ?? 0)
    }

    var hasActivePrewarmWorkerForTesting: Bool {
        prewarmWorkerTask != nil
    }

    private func computeDisplayTextPair(for item: ClipboardItemDTO, metricName: String) -> DisplayTextPair {
        if ScrollPerformanceProfile.isEnabled {
            let start = CFAbsoluteTimeGetCurrent()
            let pair = Self.computeDisplayTextPair(
                type: item.type,
                plainText: item.plainText,
                note: item.note,
                sizeBytes: item.sizeBytes,
                fileSizeBytes: item.fileSizeBytes
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            ScrollPerformanceProfile.recordTiming(name: metricName, elapsedMs: elapsed)
            return pair
        }

        return Self.computeDisplayTextPair(
            type: item.type,
            plainText: item.plainText,
            note: item.note,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes
        )
    }

    private nonisolated static func computeTitle(type: ClipboardItemType, plainText: String) -> String {
        computeDisplayTextPair(type: type, plainText: plainText, note: nil, sizeBytes: 0, fileSizeBytes: nil).title
    }

    private nonisolated static func computeMetadata(
        type: ClipboardItemType,
        plainText: String,
        note: String?,
        sizeBytes: Int,
        fileSizeBytes: Int?
    ) -> String {
        computeDisplayTextPair(
            type: type,
            plainText: plainText,
            note: note,
            sizeBytes: sizeBytes,
            fileSizeBytes: fileSizeBytes
        ).metadata
    }

    private nonisolated static func computeDisplayTextPair(
        type: ClipboardItemType,
        plainText: String,
        note: String?,
        sizeBytes: Int,
        fileSizeBytes: Int?
    ) -> DisplayTextPair {
        switch type {
        case .text, .rtf, .html:
            let textMetadata = computeTextMetadata(plainText)
            return DisplayTextPair(
                title: plainText.isEmpty ? "(No text)" : String(plainText.prefix(100)),
                metadata: textMetadata.text,
                searchMetadataPrefix: textMetadata.searchPrefix
            )
        case .image:
            return DisplayTextPair(
                title: "Image",
                metadata: computeImageMetadata(plainText, sizeBytes: sizeBytes),
                searchMetadataPrefix: nil
            )
        case .file:
            let summary = summarizeFilePlainText(plainText)
            return DisplayTextPair(
                title: computeFileTitle(plainText, summary: summary),
                metadata: computeFileMetadata(summary: summary, note: note, fileSizeBytes: fileSizeBytes),
                searchMetadataPrefix: nil
            )
        default:
            let metadata = formatBytes(sizeBytes)
            return DisplayTextPair(
                title: plainText.isEmpty ? "(No text)" : String(plainText.prefix(100)),
                metadata: metadata,
                searchMetadataPrefix: nil
            )
        }
    }

    private nonisolated static func computeFileTitle(
        _ plainText: String,
        summary: (firstPath: String?, fileCount: Int)
    ) -> String {
        let fileCount = summary.fileCount
        let firstName = URL(fileURLWithPath: summary.firstPath ?? "").lastPathComponent
        if fileCount <= 1 {
            return firstName.isEmpty ? plainText : firstName
        }
        return "\(firstName) + \(fileCount - 1) more"
    }

    private nonisolated static func computeTextMetadata(
        _ text: String
    ) -> (text: String, searchPrefix: String) {
        let summary = TextMetrics.displayWordUnitCountAndLineCount(for: text)

        // Match previous behavior:
        // - lineCount: `components(separatedBy: .newlines).count`
        // - suffix: last 15 Characters of `text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")`
        // - prefix: add "..." only when the cleaned text character count > 15
        let maxTailChars = 15

        let (suffix, needsEllipsis) = cleanTailAndEllipsis(text, maxTailChars: maxTailChars)
        let lastChars = needsEllipsis ? "...\(suffix)" : suffix
        let searchPrefix = "\(summary.wordUnitCount)字 · \(summary.lineCount)行"
        return ("\(searchPrefix) · \(lastChars)", searchPrefix)
    }

    private nonisolated static func cleanTailAndEllipsis(_ text: String, maxTailChars: Int) -> (suffix: String, needsEllipsis: Bool) {
        // Determine if cleaned text length exceeds the threshold without scanning the whole string.
        // Note: "\r\n" is a single grapheme cluster, but legacy replacement produces two spaces (two Characters),
        // so we must treat it as 2 when checking the cleaned Character count.
        var needsEllipsis = false
        var cleanedCount = 0
        for ch in text {
            if ch == "\r\n" {
                cleanedCount += 2
            } else {
                cleanedCount += 1
            }
            if cleanedCount > maxTailChars {
                needsEllipsis = true
                break
            }
        }

        var tail: [Character] = []
        tail.reserveCapacity(maxTailChars)
        var remaining = maxTailChars
        for ch in text.reversed() {
            if remaining <= 0 { break }
            if ch == "\r\n" {
                // Legacy replacement: "\r" -> " ", "\n" -> " " (two spaces).
                if remaining > 0 {
                    tail.append(" ")
                    remaining -= 1
                }
                if remaining > 0 {
                    tail.append(" ")
                    remaining -= 1
                }
                continue
            }
            if ch == "\n" || ch == "\r" {
                tail.append(" ")
                remaining -= 1
                continue
            }
            tail.append(ch)
            remaining -= 1
        }

        return (String(tail.reversed()), needsEllipsis)
    }

    private nonisolated static func computeImageMetadata(_ plainText: String, sizeBytes: Int) -> String {
        let size = formatBytes(sizeBytes)
        if let resolution = parseImageResolution(from: plainText) {
            return "\(resolution) · \(size)"
        }
        return size
    }

    private nonisolated static func computeFileMetadata(
        summary: (firstPath: String?, fileCount: Int),
        note: String?,
        fileSizeBytes: Int?
    ) -> String {
        let fileCount = summary.fileCount
        var parts: [String] = []

        if fileCount > 1 {
            parts.append("\(fileCount)个文件")
        }

        if let fileSizeBytes {
            parts.append(formatBytes(fileSizeBytes))
        } else {
            parts.append("未知大小")
        }

        if let note, !note.isEmpty {
            parts.append(note)
        }

        return parts.joined(separator: " · ")
    }

    private nonisolated static func summarizeFilePlainText(_ plainText: String) -> (firstPath: String?, fileCount: Int) {
        guard !plainText.isEmpty else { return (nil, 0) }

        var firstPath: String?
        var fileCount = 0

        var lineStart = plainText.startIndex
        var index = lineStart

        while index < plainText.endIndex {
            let ch = plainText[index]
            if ch == "\n" {
                if lineStart != index {
                    fileCount += 1
                    if firstPath == nil {
                        firstPath = String(plainText[lineStart..<index])
                    }
                }
                lineStart = plainText.index(after: index)
            }
            index = plainText.index(after: index)
        }

        if lineStart != plainText.endIndex {
            fileCount += 1
            if firstPath == nil {
                firstPath = String(plainText[lineStart..<plainText.endIndex])
            }
        }

        return (firstPath, fileCount)
    }

    private nonisolated static func parseImageResolution(from text: String) -> String? {
        let pattern = #"\[Image:\s*(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return "\(text[widthRange])×\(text[heightRange])"
    }

    private nonisolated static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }
}

extension ClipboardItemDTO {
    @MainActor var title: String { ClipboardItemDisplayText.shared.title(for: self) }
    @MainActor var metadata: String { ClipboardItemDisplayText.shared.metadata(for: self) }
}
