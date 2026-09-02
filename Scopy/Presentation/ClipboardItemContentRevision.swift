import CryptoKit
import Foundation
import ScopyKit

/// Stable content identity for presentation, preview, and future interaction-session ownership.
///
/// A non-empty backend hash remains the primary content identity. Older or synthetic DTOs can
/// lack that hash, so the fallback retains the complete text for equality and derives a
/// deterministic SHA-256 cache key. Swift's process-randomized `hashValue` is never exposed as a
/// correctness identity. Presentation-only derivatives such as `thumbnailPath` intentionally do
/// not participate: generating a thumbnail must not cancel content-bound note/export/preview work.
struct ClipboardItemContentRevision: Hashable, Sendable {
    private enum ContentIdentity: Hashable, Sendable {
        case suppliedHash(String, supplementalPlainText: String?)
        case fallbackText(String)

        var cacheComponents: [String?] {
            switch self {
            case .suppliedHash(let hash, let supplementalPlainText):
                return ["hash", hash, supplementalPlainText]
            case .fallbackText(let text):
                return ["text", text]
            }
        }
    }

    let itemID: UUID
    let type: ClipboardItemType
    let contentHash: String
    let sizeBytes: Int
    let fileSizeBytes: Int?
    let storageRef: String?
    let cacheKey: String

    private let contentIdentity: ContentIdentity

    /// Returns the revision for `item`, reusing the last one computed for the same item when every field that
    /// feeds the revision is unchanged. Rows are rebuilt on every list update during scrolling, and recomputing the
    /// digest each time measured at 11% of the main thread.
    static func resolve(item: ClipboardItemDTO) -> ClipboardItemContentRevision {
        if let cached = memo.object(forKey: item.id as NSUUID), cached.matches(item) {
            return cached.revision
        }
        let revision = ClipboardItemContentRevision(item: item)
        memo.setObject(MemoEntry(item: item, revision: revision), forKey: item.id as NSUUID)
        return revision
    }

    private static let memo: NSCache<NSUUID, MemoEntry> = {
        let cache = NSCache<NSUUID, MemoEntry>()
        cache.countLimit = 8192
        return cache
    }()

    private final class MemoEntry {
        let type: ClipboardItemType
        let contentHash: String
        let plainText: String
        let sizeBytes: Int
        let fileSizeBytes: Int?
        let storageRef: String?
        let revision: ClipboardItemContentRevision

        init(item: ClipboardItemDTO, revision: ClipboardItemContentRevision) {
            type = item.type
            contentHash = item.contentHash
            plainText = item.plainText
            sizeBytes = item.sizeBytes
            fileSizeBytes = item.fileSizeBytes
            storageRef = item.storageRef
            self.revision = revision
        }

        func matches(_ item: ClipboardItemDTO) -> Bool {
            type == item.type &&
                contentHash == item.contentHash &&
                sizeBytes == item.sizeBytes &&
                fileSizeBytes == item.fileSizeBytes &&
                storageRef == item.storageRef &&
                plainText == item.plainText
        }
    }

    init(item: ClipboardItemDTO) {
        let contentIdentity: ContentIdentity
        if item.contentHash.isEmpty {
            contentIdentity = .fallbackText(item.plainText)
        } else {
            // Text-family hashes track plain-text changes. For images, files, and other payloads,
            // `plainText` is presentation/source metadata (for example a file path or image
            // resolution) and can change without the payload hash changing.
            let supplementalPlainText: String?
            switch item.type {
            case .text, .rtf, .html:
                supplementalPlainText = nil
            case .image, .file, .other:
                supplementalPlainText = item.plainText
            }
            contentIdentity = .suppliedHash(
                item.contentHash,
                supplementalPlainText: supplementalPlainText
            )
        }

        self.itemID = item.id
        self.type = item.type
        self.contentHash = item.contentHash
        self.sizeBytes = item.sizeBytes
        self.fileSizeBytes = item.fileSizeBytes
        self.storageRef = item.storageRef
        self.contentIdentity = contentIdentity
        self.cacheKey = Self.makeCacheKey(
            itemID: item.id,
            type: item.type,
            contentIdentity: contentIdentity,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes,
            storageRef: item.storageRef
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID &&
            lhs.type == rhs.type &&
            lhs.contentIdentity == rhs.contentIdentity &&
            lhs.sizeBytes == rhs.sizeBytes &&
            lhs.fileSizeBytes == rhs.fileSizeBytes &&
            lhs.storageRef == rhs.storageRef
    }

    func hash(into hasher: inout Hasher) {
        // Hashing the precomputed compact key keeps dictionary lookup bounded for large fallback
        // text. Equality above still compares the complete fallback text, so digest collisions do
        // not become correctness collisions.
        hasher.combine(cacheKey)
    }

    static func deterministicTextCacheKey(_ text: String) -> String {
        "text-v1|\(digest(components: ["scopy-text-content-v1", text]))"
    }

    func matchesContentHash(_ expectedHash: String) -> Bool {
        !expectedHash.isEmpty && contentHash == expectedHash
    }

    private static func makeCacheKey(
        itemID: UUID,
        type: ClipboardItemType,
        contentIdentity: ContentIdentity,
        sizeBytes: Int,
        fileSizeBytes: Int?,
        storageRef: String?
    ) -> String {
        let components: [String?] = [
            "scopy-content-revision-v1",
            itemID.uuidString.lowercased(),
            type.rawValue
        ] + contentIdentity.cacheComponents + [
            String(sizeBytes),
            fileSizeBytes.map(String.init),
            storageRef
        ]

        let digest = digest(components: components)
        return "content-v1|\(itemID.uuidString.lowercased())|\(digest)"
    }

    private static func digest(components: [String?]) -> String {
        var encoded = Data()
        for component in components {
            appendLengthPrefixed(component, to: &encoded)
        }
        return hexString(SHA256.hash(data: encoded))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
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
