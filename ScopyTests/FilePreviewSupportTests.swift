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
}
