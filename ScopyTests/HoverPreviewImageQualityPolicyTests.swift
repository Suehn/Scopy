import CoreGraphics
import ImageIO
import XCTest

@testable import Scopy

final class HoverPreviewImageQualityPolicyTests: XCTestCase {
    func testImageDecodeBudgetUsesDisplayedWidthAfterEXIFRotation() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        for orientation in [1, 6] {
            let encoded = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                encoded, "public.jpeg" as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))

            let data = encoded as Data
            let displayedSize = orientation == 1 ? CGSize(width: 800, height: 200) : CGSize(width: 200, height: 800)
            XCTAssertEqual(HoverPreviewLoader.displayPixelSize(from: data), displayedSize)
            let decoded = try XCTUnwrap(HoverPreviewLoader.makePreviewCGImage(
                from: data, targetWidthPixels: 100, maxLongSidePixels: 1_000
            ))
            XCTAssertEqual(decoded.width, 100, "The width budget applies to the oriented preview")
            XCTAssertEqual(decoded.height, orientation == 1 ? 25 : 400)
        }
    }

    func testPlanKeepsFullScaleForNormalImages() {
        let plan = HoverPreviewImageQualityPolicy.plan(
            sourceWidthPixels: 3000,
            sourceHeightPixels: 2000,
            idealTargetWidthPixels: 1280
        )
        XCTAssertEqual(plan.scaleFactor, 1.0, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveTargetWidthPixels, 1280)
        XCTAssertEqual(plan.maxPixelSize, 1280)
        XCTAssertGreaterThan(plan.effectiveTargetHeightPixels, 0)
        XCTAssertLessThan(plan.effectiveTargetHeightPixels, 1280)
    }

    func testPlanReducesScaleForVeryTallImagesToFitPixelBudget() {
        let plan = HoverPreviewImageQualityPolicy.plan(
            sourceWidthPixels: 2000,
            sourceHeightPixels: 100_000,
            idealTargetWidthPixels: 1280
        )
        XCTAssertLessThan(plan.scaleFactor, 1.0)
        XCTAssertGreaterThan(plan.scaleFactor, 0.85)
        XCTAssertGreaterThan(plan.effectiveTargetWidthPixels, 1_100)
        XCTAssertLessThanOrEqual(plan.maxPixelSize, HoverPreviewImageQualityPolicy.maxSidePixels)
    }

    func testPlanRespectsMaxSidePixelsForExtremeTallImages() {
        let plan = HoverPreviewImageQualityPolicy.plan(
            sourceWidthPixels: 1000,
            sourceHeightPixels: 100_000,
            idealTargetWidthPixels: 1280
        )
        XCTAssertLessThan(plan.scaleFactor, 1.0)
        XCTAssertLessThanOrEqual(plan.maxPixelSize, HoverPreviewImageQualityPolicy.maxSidePixels)
        XCTAssertGreaterThan(plan.maxPixelSize, 10_000)
    }

    func testPlanDoesNotBudgetForUpscalingBeyondSourceWidth() {
        let plan = HoverPreviewImageQualityPolicy.plan(
            sourceWidthPixels: 1080,
            sourceHeightPixels: 61_572,
            idealTargetWidthPixels: 1280
        )
        XCTAssertLessThan(plan.scaleFactor, 1.0)
        XCTAssertGreaterThan(plan.scaleFactor, 0.95)
        XCTAssertGreaterThanOrEqual(plan.effectiveTargetWidthPixels, 1_000)
        XCTAssertLessThanOrEqual(plan.maxPixelSize, HoverPreviewImageQualityPolicy.maxSidePixels)
    }
}
