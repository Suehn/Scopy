import Foundation
import XCTest

@testable import Scopy
@testable import ScopyKit

@MainActor
final class HistoryProfileDatasetFingerprintTests: XCTestCase {
    func testFixedDatasetMetadataMatchesActualRowsAndIsDeterministic() {
        let items = MockClipboardService.makeFixedWarmTextDataset()
        let first = HistoryProfileDatasetFingerprint.make(
            datasetID: MockClipboardService.fixedWarmTextDatasetID,
            items: items
        )
        let second = HistoryProfileDatasetFingerprint.make(
            datasetID: MockClipboardService.fixedWarmTextDatasetID,
            items: items
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.schema, HistoryProfileDatasetFingerprint.schema)
        XCTAssertEqual(first.datasetID, MockClipboardService.fixedWarmTextDatasetID)
        XCTAssertTrue(first.fingerprint.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil)
        XCTAssertEqual(first.itemCount, 50)
        XCTAssertEqual(first.textItemCount, 50)
        XCTAssertEqual(first.imageItemCount, 0)
        XCTAssertEqual(first.pinnedItemCount, 2)
        XCTAssertEqual(first.uniqueItemIDCount, 50)
        XCTAssertEqual(first.minimumTextUTF8Bytes, 4_096)
        XCTAssertEqual(first.maximumTextUTF8Bytes, 4_096)
    }

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

    func testJSONPayloadUsesValidatorSchemaKeys() {
        let metadata = HistoryProfileDatasetFingerprint.make(
            datasetID: MockClipboardService.fixedWarmTextDatasetID,
            items: MockClipboardService.makeFixedWarmTextDataset()
        )

        XCTAssertEqual(metadata.jsonPayload["schema"] as? String, "history-profile-dataset-v1")
        XCTAssertEqual(metadata.jsonPayload["id"] as? String, "fixed-warm-text-v1")
        XCTAssertEqual(metadata.jsonPayload["item_count"] as? Int, 50)
        XCTAssertEqual(metadata.jsonPayload["text_utf8_bytes_min"] as? Int, 4_096)
        XCTAssertEqual(metadata.jsonPayload["text_utf8_bytes_max"] as? Int, 4_096)
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
            storageRef: item.storageRef
        )
    }
}
