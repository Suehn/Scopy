import Foundation
import ScopyKit
import XCTest

@testable import Scopy

@MainActor
final class ClipboardItemContentRevisionTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            ClipboardItemDisplayText.shared.clearCaches()
            HistoryItemPresentationCache.shared.clearCaches()
        }
        super.tearDown()
    }

    func testSameIDMissingHashSeparatesEqualLengthContent() {
        let itemID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let first = makeItem(id: itemID, contentHash: "", plainText: "AB")
        let replacement = makeItem(id: itemID, contentHash: "", plainText: "CD")

        let firstRevision = ClipboardItemContentRevision(item: first)
        let replacementRevision = ClipboardItemContentRevision(item: replacement)

        XCTAssertNotEqual(firstRevision, replacementRevision)
        XCTAssertNotEqual(firstRevision.cacheKey, replacementRevision.cacheKey)
        XCTAssertNotEqual(
            ClipboardItemContentRevision.deterministicTextCacheKey(first.plainText),
            ClipboardItemContentRevision.deterministicTextCacheKey(replacement.plainText)
        )
    }

    func testSameIDChangedSuppliedHashCreatesNewRevision() {
        let itemID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let first = makeItem(id: itemID, contentHash: "content-a", plainText: "same display text")
        let replacement = makeItem(id: itemID, contentHash: "content-b", plainText: "same display text")

        XCTAssertNotEqual(
            ClipboardItemContentRevision(item: first),
            ClipboardItemContentRevision(item: replacement)
        )
    }

    func testConstructionIsStableAcrossNonContentChanges() {
        let itemID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let first = makeItem(
            id: itemID,
            contentHash: "",
            plainText: "stable fallback",
            note: nil,
            lastUsedAt: Date(timeIntervalSince1970: 1),
            isPinned: false
        )
        let sameContent = makeItem(
            id: itemID,
            contentHash: "",
            plainText: "stable fallback",
            note: "presentation note",
            lastUsedAt: Date(timeIntervalSince1970: 2),
            isPinned: true
        )

        let firstRevision = ClipboardItemContentRevision(item: first)
        let secondRevision = ClipboardItemContentRevision(item: sameContent)

        XCTAssertEqual(firstRevision, secondRevision)
        XCTAssertEqual(firstRevision.cacheKey, secondRevision.cacheKey)
        XCTAssertEqual(
            firstRevision.cacheKey,
            "content-v1|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|" +
                "8337686fa0a8cfb2737c1a9a0356009f9790b255be174d673cc80702b3a002d5"
        )
        XCTAssertEqual(
            ClipboardItemContentRevision.deterministicTextCacheKey(first.plainText),
            "text-v1|905a73d5a62aee7a369e34d29ad978ce4481dcb2012c924fa4f356d6722c8b17"
        )
        assertSendable(firstRevision)
    }

    func testContentLocationParticipatesInRevision() {
        let itemID = UUID(uuidString: "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb")!
        let first = makeItem(
            id: itemID,
            contentHash: "image-hash",
            plainText: "Image",
            storageRef: "/tmp/first.png"
        )
        let replacement = makeItem(
            id: itemID,
            contentHash: "image-hash",
            plainText: "Image",
            storageRef: "/tmp/second.png"
        )

        XCTAssertNotEqual(
            ClipboardItemContentRevision(item: first),
            ClipboardItemContentRevision(item: replacement)
        )
    }

    func testNonTextPresentationSourceParticipatesWhenSuppliedHashIsUnchanged() {
        let itemID = UUID(uuidString: "ffffffff-1111-2222-3333-444444444444")!
        let first = makeItem(
            id: itemID,
            contentHash: "shared-binary-hash",
            plainText: "[Image: 100x100]",
            storageRef: "/tmp/image.png"
        )
        let replacement = makeItem(
            id: itemID,
            contentHash: "shared-binary-hash",
            plainText: "[Image: 200x200]",
            storageRef: "/tmp/image.png"
        )

        XCTAssertNotEqual(
            ClipboardItemContentRevision(item: first),
            ClipboardItemContentRevision(item: replacement)
        )
    }
    private func makeItem(
        id: UUID,
        contentHash: String,
        plainText: String,
        note: String? = nil,
        lastUsedAt: Date = Date(timeIntervalSince1970: 1),
        isPinned: Bool = false,
        thumbnailPath: String? = nil,
        storageRef: String? = nil
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: storageRef == nil ? .text : .image,
            contentHash: contentHash,
            plainText: plainText,
            note: note,
            appBundleID: "com.scopy.tests",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: lastUsedAt,
            isPinned: isPinned,
            sizeBytes: plainText.utf8.count,
            fileSizeBytes: nil,
            thumbnailPath: thumbnailPath,
            storageRef: storageRef
        )
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
