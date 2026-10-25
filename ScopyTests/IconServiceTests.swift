import XCTest
@testable import ScopyUISupport

@MainActor
final class IconServiceTests: XCTestCase {
    func testMissingApplicationSharesNegativeLookupAcrossNameAndIcon() {
        let service = IconService.makeForTesting()
        let bundleID = "scopy.tests.missing.\(UUID().uuidString)"
        XCTAssertNil(service.icon(bundleID: bundleID))
        XCTAssertEqual(service.appName(bundleID: bundleID), bundleID)
        XCTAssertNil(service.icon(bundleID: bundleID))
        XCTAssertEqual(service.lookupCountForTesting, 1)

        service.clearAll()
        XCTAssertEqual(service.appName(bundleID: bundleID), bundleID)
        XCTAssertEqual(service.lookupCountForTesting, 2)
    }

    func testNameLookupKeepsIconLazyAndSharesTheApplicationResolution() {
        let service = IconService.makeForTesting()
        let bundleID = "com.apple.finder"
        XCTAssertNotEqual(service.appName(bundleID: bundleID), bundleID)
        XCTAssertNil(service.cachedIcon(bundleID: bundleID))
        let icon = service.icon(bundleID: bundleID)
        XCTAssertNotNil(icon)
        XCTAssertTrue(icon === service.cachedIcon(bundleID: bundleID))
        XCTAssertEqual(service.lookupCountForTesting, 1)
    }
}
