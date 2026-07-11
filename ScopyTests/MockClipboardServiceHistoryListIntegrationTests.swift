import XCTest
@testable import ScopyKit

@MainActor
final class MockClipboardServiceHistoryListIntegrationTests: XCTestCase {
    func testIntegrationDatasetIsDeterministicAndKeepsTargetsAtTop() {
        let first = MockClipboardService.makeHistoryListIntegrationDataset()
        let second = MockClipboardService.makeHistoryListIntegrationDataset()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, MockClipboardService.historyListIntegrationItemCount)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(first.map(\.id).count, Set(first.map(\.id)).count)
        XCTAssertTrue(first.allSatisfy { !$0.isPinned })

        XCTAssertEqual(first[0].id, MockClipboardService.historyListIntegrationImageTargetID)
        XCTAssertEqual(first[0].type, .image)
        XCTAssertEqual(first[1].id, MockClipboardService.historyListIntegrationFileTargetID)
        XCTAssertEqual(first[1].type, .file)
        XCTAssertNil(first[1].note)
        XCTAssertTrue(zip(first, first.dropFirst()).allSatisfy {
            $0.0.lastUsedAt > $0.1.lastUsedAt
        })
    }

    func testIntegrationNoteDelayIsBoundedToDeterministicWindow() {
        XCTAssertEqual(MockClipboardService.boundedUITestNoteDelayMilliseconds(nil), 700)
        XCTAssertEqual(MockClipboardService.boundedUITestNoteDelayMilliseconds("10"), 600)
        XCTAssertEqual(MockClipboardService.boundedUITestNoteDelayMilliseconds("675"), 675)
        XCTAssertEqual(MockClipboardService.boundedUITestNoteDelayMilliseconds("900"), 900)
        XCTAssertEqual(MockClipboardService.boundedUITestNoteDelayMilliseconds("2500"), 2_000)
        XCTAssertEqual(MockClipboardService.boundedUITestNoteDelayMilliseconds("invalid"), 700)
    }
}
