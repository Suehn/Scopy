import XCTest
import Carbon.HIToolbox
import ScopyKit

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

        service.registerHandlerOnly {
            expectation.fulfill()
        }

        // Verify registration state
        XCTAssertTrue(service.isRegistered, "Should be registered in test mode")
        XCTAssertTrue(service.hasHandler, "Handler should be set")

        // Trigger handler manually
        service.triggerHandlerForTesting()

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Test 2: Unregister Handler

    func testUnregisterHandler() throws {
        let service = HotKeyService()
        service.registerHandlerOnly {}

        XCTAssertTrue(service.isRegistered)

        // Unregister
        service.unregisterHandlerOnly()

        XCTAssertFalse(service.isRegistered, "Should be unregistered")
        XCTAssertFalse(service.hasHandler, "Handler should be cleared")
    }

    // MARK: - Test 3: Re-register Replaces Handler

    func testReregisterReplacesHandler() throws {
        let service = HotKeyService()

        let handler2ShouldCall = XCTestExpectation(description: "Handler 2 should be called")

        // Register first handler
        service.registerHandlerOnly {}

        // Register second handler (should replace)
        service.registerHandlerOnly {
            handler2ShouldCall.fulfill()
        }

        service.triggerHandlerForTesting()

        wait(for: [handler2ShouldCall], timeout: 0.5)
    }

    // MARK: - Test 4: Handler Runs on Main Thread

    func testHandlerRunsOnMainThread() throws {
        let service = HotKeyService()
        let expectation = XCTestExpectation(description: "Handler executed")

        service.registerHandlerOnly {
            XCTAssertTrue(Thread.isMainThread, "Handler should run on main thread")
            expectation.fulfill()
        }

        let servicePtrValue = UInt(bitPattern: Unmanaged.passUnretained(service).toOpaque())
        withExtendedLifetime(service) {
            DispatchQueue.global().async {
                guard let servicePtr = UnsafeMutableRawPointer(bitPattern: servicePtrValue) else { return }
                let service = Unmanaged<HotKeyService>.fromOpaque(servicePtr).takeUnretainedValue()
                service.triggerHandlerForTesting()
            }
            wait(for: [expectation], timeout: 1.0)
        }

    }

    // MARK: - Test 5: Multiple Triggers

    func testMultipleTriggers() throws {
        let service = HotKeyService()
        let expectedCalls = 5

        let expectation = XCTestExpectation(description: "All calls completed")
        expectation.assertForOverFulfill = true
        expectation.expectedFulfillmentCount = expectedCalls

        service.registerHandlerOnly {
            expectation.fulfill()
        }

        // Trigger multiple times
        for _ in 0..<expectedCalls {
            service.triggerHandlerForTesting()
        }

        wait(for: [expectation], timeout: 2.0)
    }
}
