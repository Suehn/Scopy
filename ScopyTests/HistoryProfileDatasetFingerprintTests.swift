import Foundation
import XCTest

@testable import Scopy
@testable import ScopyKit

@MainActor
final class HistoryProfileDatasetFingerprintTests: XCTestCase {

    func testFingerprintChangesForEveryCanonicalIdentityBoundary() throws {
        let items = MockClipboardService.makeFixedWarmTextDataset()
        let original = HistoryProfileDatasetFingerprint.make(
            datasetID: MockClipboardService.fixedWarmTextDatasetID,
            items: items
        ).fingerprint
        let first = try XCTUnwrap(items.first)

        let replacements: [ClipboardItemDTO] = [
            replacing(first, id: UUID(uuidString: "53504359-0001-4000-8000-999999999999")),
            replacing(first, plainText: "changed" + String(first.plainText.dropFirst(7))),
            replacing(first, isPinned: false),
            replacing(first, createdAt: first.createdAt.addingTimeInterval(1)),
            replacing(first, lastUsedAt: first.lastUsedAt.addingTimeInterval(1))
        ]

        for replacement in replacements {
            var changed = items
            changed[0] = replacement
            XCTAssertNotEqual(
                HistoryProfileDatasetFingerprint.make(
                    datasetID: MockClipboardService.fixedWarmTextDatasetID,
                    items: changed
                ).fingerprint,
                original
            )
        }

        XCTAssertNotEqual(
            HistoryProfileDatasetFingerprint.make(
                datasetID: MockClipboardService.fixedWarmTextDatasetID,
                items: Array(items.reversed())
            ).fingerprint,
            original
        )
        XCTAssertNotEqual(
            HistoryProfileDatasetFingerprint.make(datasetID: "different-dataset", items: items).fingerprint,
            original
        )
    }

    private func replacing(
        _ item: ClipboardItemDTO,
        id: UUID? = nil,
        plainText: String? = nil,
        isPinned: Bool? = nil,
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) -> ClipboardItemDTO {
        let resolvedText = plainText ?? item.plainText
        return ClipboardItemDTO(
            id: id ?? item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: resolvedText,
            note: item.note,
            appBundleID: item.appBundleID,
            createdAt: createdAt ?? item.createdAt,
            lastUsedAt: lastUsedAt ?? item.lastUsedAt,
            isPinned: isPinned ?? item.isPinned,
            sizeBytes: resolvedText.utf8.count,
            fileSizeBytes: item.fileSizeBytes,
            thumbnailPath: item.thumbnailPath,
            storageRef: item.storageRef,
            useCount: item.useCount
        )
    }
}
