import XCTest

// MARK: - Async Test Utilities

extension XCTestCase {

    /// 等待异步条件满足
    func waitForCondition(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1,
        _ condition: @escaping () -> Bool,
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

    /// 等待异步条件满足（带返回值）
    func waitForValue<T>(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.1,
        _ getter: @escaping () -> T?,
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

    /// 断言异步操作最终成功
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
}

// MARK: - Collection Assertions

extension XCTestCase {

    /// 断言数组包含指定元素（按条件）
    func assertContains<T>(
        _ array: [T],
        where predicate: (T) -> Bool,
        message: String = "Array does not contain matching element",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            array.contains(where: predicate),
            message,
            file: file,
            line: line
        )
    }

    /// 断言数组按指定方式排序
    func assertSorted<T: Comparable>(
        _ array: [T],
        ascending: Bool = true,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        for i in 0..<(array.count - 1) {
            if ascending {
                XCTAssertLessThanOrEqual(
                    array[i], array[i + 1],
                    "Array not sorted ascending at index \(i)",
                    file: file, line: line
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    array[i], array[i + 1],
                    "Array not sorted descending at index \(i)",
                    file: file, line: line
                )
            }
        }
    }

    /// 断言数组唯一（无重复）
    func assertUnique<T: Hashable>(
        _ array: [T],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let set = Set(array)
        XCTAssertEqual(
            array.count, set.count,
            "Array contains \(array.count - set.count) duplicate elements",
            file: file, line: line
        )
    }
}

// MARK: - Optional Assertions

extension XCTestCase {

    /// 断言可选值非空并返回解包值
    @discardableResult
    func assertNotNil<T>(
        _ expression: @autoclosure () -> T?,
        message: String = "Expected non-nil value",
        file: StaticString = #file,
        line: UInt = #line
    ) -> T? {
        let value = expression()
        XCTAssertNotNil(value, message, file: file, line: line)
        return value
    }

    /// 断言可选值非空且满足条件
    func assertNotNilAndEqual<T: Equatable>(
        _ expression: @autoclosure () -> T?,
        _ expected: T,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let value = expression() else {
            XCTFail("Expected non-nil value equal to \(expected)", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, file: file, line: line)
    }
}

// MARK: - Error Assertions

extension XCTestCase {

    /// 断言异步操作抛出指定类型的错误
    func assertThrowsAsync<T, E: Error>(
        _ expression: @autoclosure () async throws -> T,
        errorType: E.Type,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error of type \(E.self)", file: file, line: line)
        } catch {
            XCTAssertTrue(
                error is E,
                "Expected error of type \(E.self), got \(type(of: error))",
                file: file, line: line
            )
        }
    }

    /// 断言异步操作不抛出错误
    @discardableResult
    func assertNoThrowAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #file,
        line: UInt = #line
    ) async -> T? {
        do {
            return try await expression()
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }
}

// MARK: - Timing Assertions

extension XCTestCase {

    /// 断言操作在指定时间内完成
    func assertCompletesWithin<T>(
        _ timeout: TimeInterval,
        _ operation: () async throws -> T,
        file: StaticString = #file,
        line: UInt = #line
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(
            elapsed, timeout,
            "Operation took \(String(format: "%.2f", elapsed))s, expected < \(timeout)s",
            file: file, line: line
        )

        return result
    }

    /// 断言操作至少花费指定时间（用于测试防抖等）
    func assertTakesAtLeast<T>(
        _ minTime: TimeInterval,
        _ operation: () async throws -> T,
        file: StaticString = #file,
        line: UInt = #line
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await operation()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertGreaterThanOrEqual(
            elapsed, minTime,
            "Operation took \(String(format: "%.2f", elapsed))s, expected >= \(minTime)s",
            file: file, line: line
        )

        return result
    }
}

// MARK: - MainActor Test Helpers

extension XCTestCase {

    /// 在 MainActor 上运行测试代码
    @MainActor
    func runOnMain(_ block: @MainActor () async throws -> Void) async throws {
        try await block()
    }
}
