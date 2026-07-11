import Foundation
import ScopyKit
import ScopyUISupport

/// Presentation-only cache for row-level derived values that are safe to precompute off the main thread.
@MainActor
final class HistoryItemPresentationCache {
    static let shared = HistoryItemPresentationCache()

    private struct RowDescriptorCacheKey: Hashable {
        let revision: ClipboardItemContentRevision
        let note: String?
        let appBundleID: String?
        let thumbnailPath: String?
        let showImageThumbnails: Bool
        let thumbnailHeight: Int
    }

    private struct FilePreviewCacheValue: Sendable {
        let summary: FilePreviewSummary?
    }

    private struct PrewarmSnapshot: Sendable {
        let revision: ClipboardItemContentRevision
        let plainText: String
        let shouldComputeFilePreview: Bool
        let shouldComputeMarkdownMenuSignal: Bool
    }

    private struct PrewarmEntry: Sendable {
        let revision: ClipboardItemContentRevision
        let filePreviewValue: FilePreviewCacheValue?
        let markdownMenuSignal: Bool?
    }

    private struct PrewarmIdentity: Hashable, Sendable {
        let revision: ClipboardItemContentRevision
        let computesFilePreview: Bool
        let computesMarkdownMenuSignal: Bool
    }

    private struct PrewarmWork: Sendable {
        let token: UInt64
        let cacheGeneration: UInt64
        let cancellation: PresentationPrewarmCancellationFlag
        let identities: Set<PrewarmIdentity>
        let snapshots: [PrewarmSnapshot]
    }

    private struct RelativeTimeCacheEntry {
        let revision: ClipboardItemContentRevision
        let lastUsedAt: Date
        let bucket: Int64
        let text: String
    }

    private static let defaultCacheLimit = 4_096

    private var prewarmBatchLimit: Int
    private var rowDescriptorCache: BoundedPresentationCache<RowDescriptorCacheKey, HistoryItemRowDescriptor>
    private var filePreviewCache: BoundedPresentationCache<ClipboardItemContentRevision, FilePreviewCacheValue>
    /// A heuristic used only to decide whether the context menu should offer PNG export.
    /// It must stay separate from the exact capability cache below.
    private var markdownMenuSignalCache: BoundedPresentationCache<ClipboardItemContentRevision, Bool>
    private var markdownCapabilityCache: BoundedPresentationCache<ClipboardItemContentRevision, Bool>
    // UUID-keyed replacement semantics retain at most one time generation per item.
    private var relativeTimeCache: BoundedPresentationCache<UUID, RelativeTimeCacheEntry>
    private var filePreviewPrewarmInFlight: Set<ClipboardItemContentRevision> = []
    private var markdownMenuSignalPrewarmInFlight: Set<ClipboardItemContentRevision> = []
    private var cacheGeneration: UInt64 = 0
    private var prewarmToken: UInt64 = 0
    private var prewarmWorkerTask: Task<Void, Never>?
    private var pendingPrewarmWork: PrewarmWork?
    private var activePrewarmToken: UInt64?
    private var activePrewarmCancellation: PresentationPrewarmCancellationFlag?
    private var activePrewarmIdentities: Set<PrewarmIdentity> = []
    private let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private init() {
        prewarmBatchLimit = Self.defaultCacheLimit
        rowDescriptorCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        filePreviewCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        markdownMenuSignalCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        markdownCapabilityCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        relativeTimeCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
    }

    func rowDescriptor(
        for item: ClipboardItemDTO,
        settings: SettingsDTO,
        dependencies: HistoryItemRowDescriptor.Dependencies? = nil
    ) -> HistoryItemRowDescriptor {
        let dependencies = dependencies ?? .live
        let key = Self.rowDescriptorCacheKey(for: item, settings: settings)
        if let cached = rowDescriptorCache[key] {
            ScrollPerformanceProfile.shared.incrementCounter(name: "row.descriptor_cache_hit")
            return cached
        }

        ScrollPerformanceProfile.shared.incrementCounter(name: "row.descriptor_cache_miss")

        let descriptor = HistoryItemRowDescriptor(
            item: item,
            settings: settings,
            dependencies: dependencies
        )
        rowDescriptorCache.insert(descriptor, forKey: key)
        return descriptor
    }

    func filePreview(for item: ClipboardItemDTO) -> FilePreviewSummary? {
        guard item.type == .file else { return nil }
        let key = ClipboardItemContentRevision(item: item)
        if let cached = filePreviewCache[key] {
            return cached.summary
        }

        let profileStart = ScrollPerformanceProfile.isEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let summary = Self.computeFilePreview(plainText: item.plainText)
        if let profileStart {
            ScrollPerformanceProfile.recordTiming(
                name: "row.file_preview_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - profileStart) * 1000
            )
        }
        filePreviewCache.insert(FilePreviewCacheValue(summary: summary), forKey: key)
        return summary
    }

    func canExportPNG(for item: ClipboardItemDTO, filePreview: FilePreviewSummary?) -> Bool {
        switch item.type {
        case .text, .rtf, .html:
            return markdownExportCapability(for: item)
        case .file:
            return (filePreview ?? self.filePreview(for: item))?.isMarkdown == true
        default:
            return false
        }
    }

    @discardableResult
    func prewarm(items: [ClipboardItemDTO]) -> Task<Void, Never>? {
        guard !items.isEmpty else {
            cancelSupersededPrewarm(pendingReplacement: nil)
            return nil
        }

        var scheduledFilePreviewRevisions: Set<ClipboardItemContentRevision> = []
        var scheduledMarkdownMenuRevisions: Set<ClipboardItemContentRevision> = []
        var identities: Set<PrewarmIdentity> = []
        var snapshots: [PrewarmSnapshot] = []
        snapshots.reserveCapacity(min(items.count, prewarmBatchLimit))

        for item in items where snapshots.count < prewarmBatchLimit {
            let mayScheduleFilePreview = item.type == .file
            let mayScheduleMarkdownMenuSignal =
                PerfFeatureFlags.markdownMenuSignalCacheEnabled &&
                Self.isMarkdownCandidate(type: item.type)
            guard mayScheduleFilePreview || mayScheduleMarkdownMenuSignal else { continue }

            let revision = ClipboardItemContentRevision(item: item)
            let shouldComputeFilePreview =
                mayScheduleFilePreview &&
                filePreviewCache[revision] == nil &&
                scheduledFilePreviewRevisions.insert(revision).inserted
            let shouldComputeMarkdownMenuSignal =
                mayScheduleMarkdownMenuSignal &&
                markdownCapabilityCache[revision] == nil &&
                markdownMenuSignalCache[revision] == nil &&
                scheduledMarkdownMenuRevisions.insert(revision).inserted
            guard shouldComputeFilePreview || shouldComputeMarkdownMenuSignal else { continue }
            identities.insert(
                PrewarmIdentity(
                    revision: revision,
                    computesFilePreview: shouldComputeFilePreview,
                    computesMarkdownMenuSignal: shouldComputeMarkdownMenuSignal
                )
            )
            snapshots.append(
                PrewarmSnapshot(
                    revision: revision,
                    plainText: item.plainText,
                    shouldComputeFilePreview: shouldComputeFilePreview,
                    shouldComputeMarkdownMenuSignal: shouldComputeMarkdownMenuSignal
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
                HistoryItemPresentationCache.shared.takeNextPrewarmWork()
            }) {
                var entries: [PrewarmEntry] = []
                entries.reserveCapacity(work.snapshots.count)

                for snapshot in work.snapshots {
                    guard !work.cancellation.isCancelled else { break }
                    let filePreviewValue = snapshot.shouldComputeFilePreview
                        ? FilePreviewCacheValue(
                            summary: Self.computeFilePreview(plainText: snapshot.plainText)
                        )
                        : nil
                    guard !work.cancellation.isCancelled else { break }
                    let markdownMenuSignal = snapshot.shouldComputeMarkdownMenuSignal
                        ? Self.computeMarkdownMenuSignal(plainText: snapshot.plainText)
                        : nil
                    guard !work.cancellation.isCancelled else { break }
                    entries.append(
                        PrewarmEntry(
                            revision: snapshot.revision,
                            filePreviewValue: filePreviewValue,
                            markdownMenuSignal: markdownMenuSignal
                        )
                    )
                }

                let preparedEntries = entries
                await MainActor.run {
                    HistoryItemPresentationCache.shared.completePrewarm(
                        work: work,
                        entries: preparedEntries
                    )
                }
            }
        }
        prewarmWorkerTask = task

        return task
    }

    func cachedFilePreview(for item: ClipboardItemDTO) -> FilePreviewSummary? {
        guard item.type == .file else { return nil }
        return filePreviewCache[ClipboardItemContentRevision(item: item)]?.summary
    }

    func cachedRowDescriptor(for item: ClipboardItemDTO, settings: SettingsDTO) -> HistoryItemRowDescriptor? {
        rowDescriptorCache[Self.rowDescriptorCacheKey(for: item, settings: settings)]
    }

    func cachedMarkdownExportCapability(for item: ClipboardItemDTO) -> Bool? {
        cachedMarkdownExportCapability(for: ClipboardItemContentRevision(item: item))
    }

    /// Revision overload for hot paths that already own the deterministic content identity.
    func cachedMarkdownExportCapability(for revision: ClipboardItemContentRevision) -> Bool? {
        guard Self.isMarkdownCandidate(type: revision.type) else { return nil }
        return markdownCapabilityCache[revision]
    }

    func storeMarkdownExportCapability(_ value: Bool, for item: ClipboardItemDTO) {
        guard Self.isMarkdownCandidate(type: item.type) else { return }
        let key = ClipboardItemContentRevision(item: item)
        markdownCapabilityCache.insert(value, forKey: key)
    }

    func cachedMarkdownMenuSignal(for item: ClipboardItemDTO) -> Bool? {
        cachedMarkdownMenuSignal(for: ClipboardItemContentRevision(item: item))
    }

    /// Returns only the heuristic menu signal. Exact export capability is intentionally queried
    /// by the caller first so a cached exact `false` can override a heuristic `true`.
    func cachedMarkdownMenuSignal(for revision: ClipboardItemContentRevision) -> Bool? {
        guard Self.isMarkdownCandidate(type: revision.type) else { return nil }
        return markdownMenuSignalCache[revision]
    }

    func markdownMenuSignal(for item: ClipboardItemDTO) -> Bool {
        markdownMenuSignal(
            for: ClipboardItemContentRevision(item: item),
            plainText: item.plainText
        )
    }

    /// Computes and caches both positive and negative heuristic results. The revision overload
    /// avoids rebuilding the SHA-backed identity from a row that already owns it.
    func markdownMenuSignal(
        for revision: ClipboardItemContentRevision,
        plainText: String
    ) -> Bool {
        guard Self.isMarkdownCandidate(type: revision.type) else { return false }

        guard PerfFeatureFlags.markdownMenuSignalCacheEnabled else {
            ScrollPerformanceProfile.shared.incrementCounter(
                name: "row.markdown_menu_signal_uncached"
            )
            return Self.profiledMarkdownMenuSignal(
                plainText: plainText,
                timingName: "row.markdown_menu_signal_uncached_ms"
            )
        }

        if let cached = markdownMenuSignalCache[revision] {
            ScrollPerformanceProfile.shared.incrementCounter(
                name: "row.markdown_menu_signal_cache_hit"
            )
            return cached
        }

        ScrollPerformanceProfile.shared.incrementCounter(
            name: "row.markdown_menu_signal_cache_miss"
        )
        let computed = Self.profiledMarkdownMenuSignal(
            plainText: plainText,
            timingName: "row.markdown_menu_signal_miss_ms"
        )
        markdownMenuSignalCache.insert(computed, forKey: revision)
        return computed
    }

    func relativeTimeText(
        for item: ClipboardItemDTO,
        bucket: Int64
    ) -> String {
        let revision = ClipboardItemContentRevision(item: item)
        if let cached = relativeTimeCache[item.id],
           cached.revision == revision,
           cached.lastUsedAt == item.lastUsedAt,
           cached.bucket == bucket {
            ScrollPerformanceProfile.shared.incrementCounter(name: "row.relative_time_cache_hit")
            return cached.text
        }

        let referenceDate = Date(
            timeIntervalSince1970: TimeInterval(bucket) * HistoryRelativeTimeClock.bucketDuration
        )
        let text = relativeTimeFormatter.localizedString(
            for: item.lastUsedAt,
            relativeTo: referenceDate
        )
        relativeTimeCache.insert(
            RelativeTimeCacheEntry(
                revision: revision,
                lastUsedAt: item.lastUsedAt,
                bucket: bucket,
                text: text
            ),
            forKey: item.id
        )
        ScrollPerformanceProfile.shared.incrementCounter(name: "row.relative_time_cache_miss")
        return text
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
        rowDescriptorCache.removeAll()
        filePreviewCache.removeAll()
        markdownMenuSignalCache.removeAll()
        markdownCapabilityCache.removeAll()
        relativeTimeCache.removeAll()
        filePreviewPrewarmInFlight.removeAll(keepingCapacity: true)
        markdownMenuSignalPrewarmInFlight.removeAll(keepingCapacity: true)
    }

    func markdownExportCapability(for item: ClipboardItemDTO) -> Bool {
        guard Self.isMarkdownCandidate(type: item.type) else { return false }
        let key = ClipboardItemContentRevision(item: item)
        if let cached = markdownCapabilityCache[key] {
            return cached
        }

        let computed: Bool
        if ScrollPerformanceProfile.isEnabled {
            let start = CFAbsoluteTimeGetCurrent()
            computed = MarkdownDetector.isLikelyMarkdown(item.plainText)
            ScrollPerformanceProfile.recordTiming(
                name: "text.markdown_detect_ms",
                elapsedMs: (CFAbsoluteTimeGetCurrent() - start) * 1000
            )
        } else {
            computed = MarkdownDetector.isLikelyMarkdown(item.plainText)
        }
        markdownCapabilityCache.insert(computed, forKey: key)
        return computed
    }

    private func storePrewarmEntries(_ entries: [PrewarmEntry]) {
        for entry in entries {
            if let filePreviewValue = entry.filePreviewValue {
                filePreviewCache.insert(filePreviewValue, forKey: entry.revision)
            }
            if let markdownMenuSignal = entry.markdownMenuSignal {
                markdownMenuSignalCache.insert(markdownMenuSignal, forKey: entry.revision)
            }
        }
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
        filePreviewPrewarmInFlight = Set(
            work.identities.lazy
                .filter(\.computesFilePreview)
                .map(\.revision)
        )
        markdownMenuSignalPrewarmInFlight = Set(
            work.identities.lazy
                .filter(\.computesMarkdownMenuSignal)
                .map(\.revision)
        )
        return work
    }

    private func completePrewarm(work: PrewarmWork, entries: [PrewarmEntry]) {
        guard activePrewarmToken == work.token else { return }
        activePrewarmToken = nil
        activePrewarmCancellation = nil
        activePrewarmIdentities.removeAll(keepingCapacity: true)
        filePreviewPrewarmInFlight.removeAll(keepingCapacity: true)
        markdownMenuSignalPrewarmInFlight.removeAll(keepingCapacity: true)

        guard !work.cancellation.isCancelled,
              cacheGeneration == work.cacheGeneration else { return }
        storePrewarmEntries(entries)
    }

    func configureCacheCapacityForTesting(_ capacity: Int) {
        precondition(capacity > 0)
        clearCaches()
        prewarmBatchLimit = capacity
        rowDescriptorCache = BoundedPresentationCache(capacity: capacity)
        filePreviewCache = BoundedPresentationCache(capacity: capacity)
        markdownMenuSignalCache = BoundedPresentationCache(capacity: capacity)
        markdownCapabilityCache = BoundedPresentationCache(capacity: capacity)
        relativeTimeCache = BoundedPresentationCache(capacity: capacity)
    }

    func restoreDefaultCacheCapacityForTesting() {
        clearCaches()
        prewarmBatchLimit = Self.defaultCacheLimit
        rowDescriptorCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        filePreviewCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        markdownMenuSignalCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        markdownCapabilityCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
        relativeTimeCache = BoundedPresentationCache(capacity: Self.defaultCacheLimit)
    }

    var relativeTimeEntryCountForTesting: Int {
        relativeTimeCache.count
    }

    var markdownMenuSignalEntryCountForTesting: Int {
        markdownMenuSignalCache.count
    }

    var cacheEntryCountsForTesting: (
        rowDescriptor: Int,
        filePreview: Int,
        markdownMenuSignal: Int,
        markdownCapability: Int,
        relativeTime: Int
    ) {
        (
            rowDescriptorCache.count,
            filePreviewCache.count,
            markdownMenuSignalCache.count,
            markdownCapabilityCache.count,
            relativeTimeCache.count
        )
    }

    var prewarmInFlightCountForTesting: Int {
        activePrewarmIdentities.count + (pendingPrewarmWork?.identities.count ?? 0)
    }

    var activePrewarmInFlightCountForTesting: Int {
        activePrewarmIdentities.count
    }

    var hasActivePrewarmWorkerForTesting: Bool {
        prewarmWorkerTask != nil
    }

    func relativeTimeBucketForTesting(itemID: UUID) -> Int64? {
        relativeTimeCache[itemID]?.bucket
    }

    private static func rowDescriptorCacheKey(
        for item: ClipboardItemDTO,
        settings: SettingsDTO
    ) -> RowDescriptorCacheKey {
        RowDescriptorCacheKey(
            revision: ClipboardItemContentRevision(item: item),
            note: item.note,
            appBundleID: item.appBundleID,
            thumbnailPath: item.thumbnailPath,
            showImageThumbnails: settings.showImageThumbnails,
            thumbnailHeight: settings.thumbnailHeight
        )
    }

    private nonisolated static func isMarkdownCandidate(type: ClipboardItemType) -> Bool {
        switch type {
        case .text, .rtf, .html:
            return true
        default:
            return false
        }
    }

    private nonisolated static func computeFilePreview(plainText: String) -> FilePreviewSummary? {
        FilePreviewSupport.previewSummary(from: plainText, requireExists: false)
    }

    private nonisolated static func computeMarkdownMenuSignal(plainText: String) -> Bool {
        MarkdownDetector.hasFastMarkdownSignal(plainText)
    }

    @MainActor
    private static func profiledMarkdownMenuSignal(
        plainText: String,
        timingName: String
    ) -> Bool {
        guard ScrollPerformanceProfile.isEnabled else {
            return computeMarkdownMenuSignal(plainText: plainText)
        }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = computeMarkdownMenuSignal(plainText: plainText)
        ScrollPerformanceProfile.shared.recordTiming(
            name: timingName,
            elapsedMs: (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
        )
        return result
    }
}
