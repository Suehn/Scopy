import XCTest

final class MarkdownExportSizingTests: XCTestCase {
    func testDownscaledSizeClampsShortSideTo1500WhenSourceIsLarger() {
        let out = MarkdownExportRenderer.computeDownscaledPixelSizeIfNeeded(
            srcWidth: 2400,
            srcHeight: 1600,
            maxShortSidePixels: 1500,
            maxLongSidePixels: 16_384 * 4
        )
        XCTAssertEqual(out.shortSide, 1500)
    }

    func testScaledSizeClampsWhenLongSideWouldExceedLimit() {
        let out = MarkdownExportRenderer.computeDownscaledPixelSizeIfNeeded(
            srcWidth: 2000,
            srcHeight: 60_000,
            maxShortSidePixels: 1500,
            maxLongSidePixels: 16_384 * 4
        )
        XCTAssertLessThanOrEqual(max(out.width, out.height), 16_384 * 4)
        XCTAssertLessThanOrEqual(out.shortSide, 1500)
        XCTAssertGreaterThan(out.shortSide, 0)
    }

    func testDownscaledSizeDoesNotUpscaleWhenSourceIsSmallerThanMax() {
        let out = MarkdownExportRenderer.computeDownscaledPixelSizeIfNeeded(
            srcWidth: 600,
            srcHeight: 400,
            maxShortSidePixels: 1500,
            maxLongSidePixels: 16_384 * 4
        )
        XCTAssertEqual(out.width, 600)
        XCTAssertEqual(out.height, 400)
        XCTAssertEqual(out.shortSide, 400)
    }
}
