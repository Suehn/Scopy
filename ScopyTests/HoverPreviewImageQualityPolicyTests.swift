import XCTest

@testable import Scopy

final class HoverPreviewImageQualityPolicyTests: XCTestCase {
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
            sourceHeightPixels: 50_000,
            idealTargetWidthPixels: 1280
        )
        XCTAssertLessThan(plan.scaleFactor, 1.0)
        XCTAssertGreaterThan(plan.scaleFactor, 0.70)
        XCTAssertGreaterThan(plan.effectiveTargetWidthPixels, 900)
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
}

