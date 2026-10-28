import Foundation

// MARK: - Service Protocol

/// The UI's interface to the clipboard backend: structured data and commands, no UI concerns.
@MainActor
public protocol ClipboardServiceProtocol: AnyObject {
    // MARK: - Lifecycle

    /// Starts the service: the real one opens the database and starts monitoring; a mock may do nothing.
    func start() async throws

    /// Stops the service and waits for its producers and resource cleanup to finish.
    func stopAndWait() async

    // MARK: - Data Access

    /// Recent clipboard items.
    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO]

    /// Pinned items. The UI groups them separately, so they do not count against a recent page.
    func fetchPinned() async throws -> [ClipboardItemDTO]

    /// The recent page after `cursor`, or the first page with every pinned row when it is `nil`.
    func fetchHistoryPage(limit: Int, after cursor: RecentHistoryCursor?) async throws -> RecentHistoryPage

    /// Authoritative states for explicitly retained rows, from one read snapshot.
    func fetchHistoryItems(itemIDs: Set<UUID>) async throws -> HistoryItemsSnapshot

    /// Searches the clipboard history.
    func search(query: SearchRequest) async throws -> SearchResultPage

    /// Pins or unpins an item.
    func pin(itemID: UUID) async throws
    func unpin(itemID: UUID) async throws

    /// Updates an item's note (used for file items).
    func updateNote(itemID: UUID, note: String?) async throws

    /// Deletes only the usage the user selected. A newer copy retains the row; the returned
    /// snapshot records that decision and its exact requested identity in the same transaction.
    func delete(itemID: UUID, expectedUseCount: Int) async throws -> HistoryItemsSnapshot

    /// Clears the history. Publishes the committed clear before returning; view state follows it.
    func clearAll() async throws

    /// Copies an item to the system pasteboard.
    func copyToClipboard(itemID: UUID) async throws

    /// Prepares a compatible image representation for narrow image readers such as Codex.
    /// Only an explicit user action triggers it, so ordinary paste semantics stay unchanged.
    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws

    /// Local file URLs for the system share sheet: the original file for file items, a temporary PNG for images.
    func fileURLs(itemID: UUID) async throws -> [URL]

    /// Commits changed fields atomically and returns the persisted settings.
    func updateSettings(_ patch: SettingsPatch) async throws -> SettingsDTO

    /// The current settings.
    func getSettings() async throws -> SettingsDTO

    /// Storage statistics.
    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int)

    /// Detailed storage statistics.
    func getDetailedStorageStats() async throws -> StorageStatsDTO

    /// An image item's original data, for preview.
    func getImageData(itemID: UUID) async throws -> Data?

    /// Optimizes a history image with pngquant, replacing the original and updating its hash and size.
    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO

    /// After images under `content/` are recompressed outside the app, the stored `size_bytes`
    /// overstate the content estimate and mislead cleanup; this reads each external image's real
    /// file size from disk and writes it back.
    ///
    /// - Returns: The number of items whose `size_bytes` changed.
    func syncExternalImageSizeBytesFromDisk() async throws -> Int

    /// Recently used source apps, for the app filter.
    func getRecentApps(limit: Int) async throws -> [String]

    /// Backend events: new items, deletions, settings changes, and so on.
    var eventStream: AsyncStream<ClipboardEvent> { get }
}
