import XCTest

extension XCUIApplication {
    func anyElement(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    func anyElements(matching predicate: NSPredicate) -> XCUIElementQuery {
        descendants(matching: .any).matching(predicate)
    }
}

extension XCTestCase {
    func waitForPredicate(
        _ predicate: NSPredicate,
        on object: Any,
        timeout: TimeInterval = 5.0,
        message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, message, file: file, line: line)
    }
}
