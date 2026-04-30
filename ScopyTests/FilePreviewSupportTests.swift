import XCTest
@testable import ScopyKit

final class FilePreviewSupportTests: XCTestCase {
    func testShouldUseQuickLookPreviewOnlyForOtherFiles() {
        XCTAssertFalse(FilePreviewSupport.shouldUseQuickLookPreview(for: .image))
        XCTAssertFalse(FilePreviewSupport.shouldUseQuickLookPreview(for: .video))
        XCTAssertTrue(FilePreviewSupport.shouldUseQuickLookPreview(for: .other))
    }

    func testKindDetectsMovieFileAsVideo() {
        let url = URL(fileURLWithPath: "/tmp/demo.mp4")
        XCTAssertEqual(FilePreviewSupport.kind(for: url), .video)
    }

    func testPreviewSummaryPreservesExistenceBoundary() throws {
        let missingPath = "/tmp/scopy-missing-\(UUID().uuidString).md"

        let displaySummary = try XCTUnwrap(FilePreviewSupport.previewSummary(from: missingPath, requireExists: false))
        XCTAssertEqual(displaySummary.path, missingPath)
        XCTAssertTrue(displaySummary.isMarkdown)
        XCTAssertFalse(displaySummary.shouldGenerateThumbnail)

        XCTAssertNil(FilePreviewSupport.previewSummary(from: missingPath, requireExists: true))
    }
}
