import XCTest
import Carbon.HIToolbox
#if !SCOPY_TSAN_TESTS
@testable import Scopy
#endif

/// HotKeyService 单元测试
/// 验证全局快捷键的处理器管理和触发逻辑
/// 注意：使用测试模式 API 避免实际注册 Carbon 热键
final class HotKeyServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HotKeyService.enableTestingMode()
    }

    override func tearDown() {
        HotKeyService.disableTestingMode()
        super.tearDown()
    }

    // MARK: - Test 1: Register and Trigger Handler

    func testRegisterHandlerAndTrigger() throws {
        let service = HotKeyService()
        let expectation = XCTestExpectation(description: "Handler should be called")

        var handlerCalled = false
        service.registerHandlerOnly {
            handlerCalled = true
            expectation.fulfill()
        }

        // Verify registration state
        XCTAssertTrue(service.isRegistered, "Should be registered in test mode")
        XCTAssertTrue(service.hasHandler, "Handler should be set")

        // Trigger handler manually
        service.triggerHandlerForTesting()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(handlerCalled, "Handler should have been called")
    }

    // MARK: - Test 2: Unregister Handler

    func testUnregisterHandler() throws {
        let service = HotKeyService()
        var callCount = 0

        service.registerHandlerOnly {
            callCount += 1
        }

        XCTAssertTrue(service.isRegistered)

        // Unregister
        service.unregisterHandlerOnly()

        XCTAssertFalse(service.isRegistered, "Should be unregistered")
        XCTAssertFalse(service.hasHandler, "Handler should be cleared")

        // Trigger should not call handler (handler is nil)
        service.triggerHandlerForTesting()

        // Give async dispatch time to run (if it would)
        let expectation = XCTestExpectation(description: "Wait")
        expectation.isInverted = true
        wait(for: [expectation], timeout: 0.1)

        XCTAssertEqual(callCount, 0, "Handler should not be called after unregister")
    }

    // MARK: - Test 3: Re-register Replaces Handler

    func testReregisterReplacesHandler() throws {
        let service = HotKeyService()

        var handler1Called = false
        var handler2Called = false

        // Register first handler
        service.registerHandlerOnly {
            handler1Called = true
        }

        // Register second handler (should replace)
        service.registerHandlerOnly {
            handler2Called = true
        }

        let expectation = XCTestExpectation(description: "Handler 2 called")
        service.triggerHandlerForTesting()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(handler1Called, "Old handler should not be called")
        XCTAssertTrue(handler2Called, "New handler should be called")
    }

    // MARK: - Test 4: Handler Runs on Main Thread

    func testHandlerRunsOnMainThread() throws {
        let service = HotKeyService()
        let expectation = XCTestExpectation(description: "Handler executed")

        var isMainThread = false

        service.registerHandlerOnly {
            isMainThread = Thread.isMainThread
            expectation.fulfill()
        }

        // Trigger from background thread
        DispatchQueue.global().async {
            service.triggerHandlerForTesting()
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(isMainThread, "Handler should run on main thread")
    }

    // MARK: - Test 5: Multiple Triggers

    func testMultipleTriggers() throws {
        let service = HotKeyService()
        var callCount = 0
        let expectedCalls = 5

        let expectation = XCTestExpectation(description: "All calls completed")
        expectation.expectedFulfillmentCount = expectedCalls

        service.registerHandlerOnly {
            callCount += 1
            expectation.fulfill()
        }

        // Trigger multiple times
        for _ in 0..<expectedCalls {
            service.triggerHandlerForTesting()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(callCount, expectedCalls, "Handler should be called \(expectedCalls) times")
    }

    // MARK: - Test 6: Handler Closure Capture

    func testHandlerClosureCapture() throws {
        let service = HotKeyService()
        let expectation = XCTestExpectation(description: "Handler called")

        var externalValue = "initial"

        service.registerHandlerOnly { [externalValue] in
            // Capture by value
            XCTAssertEqual(externalValue, "initial")
            expectation.fulfill()
        }

        // Change external value
        externalValue = "changed"

        service.triggerHandlerForTesting()

        wait(for: [expectation], timeout: 1.0)
    }
}
