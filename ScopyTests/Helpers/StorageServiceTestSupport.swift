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

    /// Installs a fixture replacement through the production payload transaction.
    func replacePayloadForTesting(
        id: UUID,
        contentHash: String,
        sizeBytes: Int,
        storageRef: String?,
        rawData: Data?
    ) async throws {
        guard let expected = try await findByID(id),
              try await compareAndSwapItemPayload(
                expected: expected,
                contentHash: contentHash,
                sizeBytes: sizeBytes,
                storageRef: storageRef,
                rawData: rawData
              ) != nil else {
            throw StorageError.updateFailed("Fixture payload no longer owns its row")
        }
    }
}
