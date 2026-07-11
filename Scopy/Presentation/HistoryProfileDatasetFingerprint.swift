import CryptoKit
import Foundation
import ScopyKit

/// Canonical identity for the actual ordered rows consumed by a history performance profile.
enum HistoryProfileDatasetFingerprint {
    static let schema = "history-profile-dataset-v1"

    struct Metadata: Equatable, Sendable {
        let schema: String
        let datasetID: String
        let fingerprint: String
        let itemCount: Int
        let textItemCount: Int
        let imageItemCount: Int
        let pinnedItemCount: Int
        let uniqueItemIDCount: Int
        let minimumTextUTF8Bytes: Int
        let maximumTextUTF8Bytes: Int

        var jsonPayload: [String: Any] {
            [
                "schema": schema,
                "id": datasetID,
                "fingerprint": fingerprint,
                "item_count": itemCount,
                "text_item_count": textItemCount,
                "image_item_count": imageItemCount,
                "pinned_item_count": pinnedItemCount,
                "unique_item_id_count": uniqueItemIDCount,
                "text_utf8_bytes_min": minimumTextUTF8Bytes,
                "text_utf8_bytes_max": maximumTextUTF8Bytes
            ]
        }
    }

    static func make(
        datasetID: String,
        items: [ClipboardItemDTO]
    ) -> Metadata {
        var canonical = Data()
        appendLengthPrefixed(schema, to: &canonical)
        appendLengthPrefixed(datasetID, to: &canonical)

        var textByteCounts: [Int] = []
        textByteCounts.reserveCapacity(items.count)
        var textItemCount = 0
        var imageItemCount = 0
        var pinnedItemCount = 0
        var uniqueItemIDs: Set<UUID> = []
        uniqueItemIDs.reserveCapacity(items.count)

        for (ordinal, item) in items.enumerated() {
            appendLengthPrefixed(String(ordinal), to: &canonical)
            appendLengthPrefixed(item.id.uuidString.lowercased(), to: &canonical)
            appendLengthPrefixed(item.type.rawValue, to: &canonical)
            appendLengthPrefixed(item.contentHash, to: &canonical)
            appendLengthPrefixed(item.plainText, to: &canonical)
            appendLengthPrefixed(item.note, to: &canonical)
            appendLengthPrefixed(item.appBundleID, to: &canonical)
            appendLengthPrefixed(dateBits(item.createdAt), to: &canonical)
            appendLengthPrefixed(dateBits(item.lastUsedAt), to: &canonical)
            appendLengthPrefixed(item.isPinned ? "1" : "0", to: &canonical)
            appendLengthPrefixed(String(item.sizeBytes), to: &canonical)
            appendLengthPrefixed(item.fileSizeBytes.map(String.init), to: &canonical)
            appendLengthPrefixed(item.thumbnailPath, to: &canonical)
            appendLengthPrefixed(item.storageRef, to: &canonical)

            uniqueItemIDs.insert(item.id)
            if item.isPinned {
                pinnedItemCount += 1
            }
            switch item.type {
            case .text:
                textItemCount += 1
                textByteCounts.append(item.plainText.utf8.count)
            case .image:
                imageItemCount += 1
            case .rtf, .html, .file, .other:
                break
            }
        }

        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()

        return Metadata(
            schema: schema,
            datasetID: datasetID,
            fingerprint: "sha256:\(digest)",
            itemCount: items.count,
            textItemCount: textItemCount,
            imageItemCount: imageItemCount,
            pinnedItemCount: pinnedItemCount,
            uniqueItemIDCount: uniqueItemIDs.count,
            minimumTextUTF8Bytes: textByteCounts.min() ?? 0,
            maximumTextUTF8Bytes: textByteCounts.max() ?? 0
        )
    }

    private static func dateBits(_ date: Date) -> String {
        String(date.timeIntervalSince1970.bitPattern, radix: 16)
    }

    private static func appendLengthPrefixed(_ value: String?, to data: inout Data) {
        guard let value else {
            data.append(0)
            return
        }

        data.append(1)
        let bytes = value.utf8
        let count = UInt64(bytes.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((count >> UInt64(shift)) & 0xff))
        }
        data.append(contentsOf: bytes)
    }
}
