import Foundation
@testable import ScopyKit

extension StorageService {
    /// Test convenience over `upsertItemWithOutcome` that requires a stored row.
    func upsertItem(_ content: ClipboardMonitor.ClipboardContent) async throws -> ClipboardStoredItem {
        guard let item = try await upsertItemWithOutcome(content).item else {
            throw StorageError.queryFailed("Previously applied ingest item no longer exists")
        }
        return item
    }
}
