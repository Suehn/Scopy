import XCTest

// Shared asynchronous waits used by the test suites.
extension XCTestCase {

    @MainActor
    func waitForCondition(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1,
        _ condition: @MainActor @escaping () -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
    }

    @MainActor
    func waitForValue<T>(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1,
        _ getter: @MainActor @escaping () -> T?,
        file: StaticString = #file,
        line: UInt = #line
    ) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let value = getter() {
                return value
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        XCTFail("Value not available within \(timeout) seconds", file: file, line: line)
        return nil
    }

    @MainActor
    func assertEventually(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1,
        _ assertion: @escaping () -> Bool,
        message: String = "Assertion did not become true",
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if assertion() {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        XCTFail(message, file: file, line: line)
    }

    @MainActor
    func waitForConditionAsync(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1,
        _ condition: @MainActor @escaping () async -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
    }
}
