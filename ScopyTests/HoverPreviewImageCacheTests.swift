import CoreGraphics
import XCTest

@testable import Scopy

@MainActor
final class HoverPreviewImageCacheTests: XCTestCase {
    func testCacheReturnsAndExpiresWithSlidingTTL() async {
        var now = Date(timeIntervalSince1970: 0)
        let cache = HoverPreviewImageCache(ttl: 60, now: { now })

        let image = makeTestImage(width: 8, height: 8)
        cache.setImage(image, forKey: "k")

        XCTAssertNotNil(cache.image(forKey: "k"))

        now = Date(timeIntervalSince1970: 59)
        XCTAssertNotNil(cache.image(forKey: "k"))

        now = Date(timeIntervalSince1970: 120)
        XCTAssertNil(cache.image(forKey: "k"))
    }

    func testCleanupLoopRunsOnlyWhileEntriesExist() async {
        let cache = HoverPreviewImageCache(ttl: 0.01, cleanupInterval: 0.02)
        XCTAssertFalse(cache.isCleanupLoopRunning)

        cache.setImage(makeTestImage(width: 8, height: 8), forKey: "k")
        XCTAssertTrue(cache.isCleanupLoopRunning)

        let deadline = Date().addingTimeInterval(2)
        while cache.isCleanupLoopRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(cache.isCleanupLoopRunning, "The sweep stops once the expired entry is gone")
        XCTAssertNil(cache.image(forKey: "k"))
    }

    private func makeTestImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        XCTAssertNotNil(ctx)
        return ctx!.makeImage()!
    }
}

