import CryptoKit
import Foundation
import XCTest

@testable import ScopyKit

@MainActor
final class MockClipboardServiceFixedDatasetTests: XCTestCase {
    func testFixedWarmTextDatasetHasExactStableShape() throws {
        let first = MockClipboardService.makeFixedWarmTextDataset()
        let second = MockClipboardService.makeFixedWarmTextDataset()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, MockClipboardService.fixedWarmTextItemCount)
        XCTAssertEqual(first.filter(\.isPinned).count, MockClipboardService.fixedWarmTextPinnedCount)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
        XCTAssertTrue(first.allSatisfy { $0.type == .text })
        XCTAssertTrue(first.allSatisfy { $0.plainText.utf8.count == MockClipboardService.fixedWarmTextLength })
        XCTAssertTrue(first.allSatisfy { $0.sizeBytes == $0.plainText.utf8.count })
        XCTAssertTrue(first.allSatisfy { $0.fileSizeBytes == nil })
        XCTAssertTrue(first.allSatisfy { $0.thumbnailPath == nil })
        XCTAssertTrue(first.allSatisfy { $0.storageRef == nil })
        XCTAssertEqual(
            try XCTUnwrap(first.first).id.uuidString,
            "53504359-0001-4000-8000-000000000000"
        )
    }

    func testFixedWarmTextDatasetHashesAndOrderingMatchPayloads() {
        let items = MockClipboardService.makeFixedWarmTextDataset()

        for item in items {
            XCTAssertEqual(item.contentHash, sha256Hex(item.plainText))
        }
        for (newer, older) in zip(items, items.dropFirst()) {
            XCTAssertGreaterThan(newer.lastUsedAt, older.lastUsedAt)
            XCTAssertEqual(newer.createdAt, newer.lastUsedAt.addingTimeInterval(-30))
        }
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
