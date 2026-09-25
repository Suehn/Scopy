import Foundation

// MARK: - Service Protocol

/// The UI's interface to the clipboard backend: structured data and commands, no UI concerns.
@MainActor
public protocol ClipboardServiceProtocol: AnyObject {
    // MARK: - Lifecycle

    /// Starts the service: the real one opens the database and starts monitoring; a mock may do nothing.
    func start() async throws

    /// Stops the service and releases its resources.
    func stop()

    /// Stops the service and waits for cleanup to finish (tests and quit), instead of sleeping.
    func stopAndWait() async

    // MARK: - Data Access

    /// Recent clipboard items.
    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO]

    /// Pinned items. The UI groups them separately, so they do not count against a recent page.
    func fetchPinned() async throws -> [ClipboardItemDTO]

    /// Recent unpinned items, for paging the recent list.
    func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO]

    /// Searches the clipboard history.
    func search(query: SearchRequest) async throws -> SearchResultPage

    /// Pins or unpins an item.
    func pin(itemID: UUID) async throws
    func unpin(itemID: UUID) async throws

    /// Updates an item's note (used for file items).
    func updateNote(itemID: UUID, note: String?) async throws

    /// Deletes an item.
    func delete(itemID: UUID) async throws

    /// Clears the history. Must publish or forward `.itemsCleared` before returning; view state follows that event.
    func clearAll() async throws

    /// Copies an item to the system pasteboard.
    func copyToClipboard(itemID: UUID) async throws

    /// Prepares a compatible image representation for narrow image readers such as Codex.
    /// Only an explicit user action triggers it, so ordinary paste semantics stay unchanged.
    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws

    /// Local file URLs for the system share sheet: the original file for file items, a temporary PNG for images.
    func fileURLs(itemID: UUID) async throws -> [URL]

    /// Updates the settings.
    func updateSettings(_ settings: SettingsDTO) async throws

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
