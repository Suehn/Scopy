import XCTest
@testable import ScopyKit

/// 资源清理测试 - v0.10.4
/// 验证 Timer、Task、事件流、数据库连接等资源的正确清理
@MainActor
final class ResourceCleanupTests: XCTestCase {

    // MARK: - Storage Cleanup Tests

    /// 测试数据库连接在 close 后正确释放
    func testDatabaseConnectionCleanup() async throws {
        let storage = StorageService(databasePath: ":memory:")
        try await storage.open()

        // 插入一些数据
        let content = ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: "Test content",
            payload: .none,
            appBundleID: nil,
            contentHash: "test_hash",
            sizeBytes: 12
        )
        _ = try await storage.upsertItem(content)

        // 关闭数据库
        await storage.close()

        // 验证数据库已关闭（后续 DB 调用应失败）
        do {
            _ = try await storage.getItemCount()
            XCTFail("Expected databaseNotOpen after close")
        } catch {
            // Expected
        }
    }

    /// 测试 sqlite3_step 错误处理
    func testSqliteStepErrorHandling() async throws {
        var cleanupPolicy = StorageService.CleanupPolicy()
        let storage = StorageService(databasePath: ":memory:")
        try await storage.open()

        // 插入测试数据
        for i in 0..<5 {
            let content = ClipboardMonitor.ClipboardContent(
                type: .text,
                plainText: "Item \(i)",
                payload: .none,
                appBundleID: nil,
                contentHash: "hash_\(i)",
                sizeBytes: 10
            )
            _ = try await storage.upsertItem(content)
        }

        // 正常清理应该成功
        cleanupPolicy.maxItems = 3
        do {
            try await storage.performCleanup(policy: cleanupPolicy)
        } catch {
            XCTFail("Cleanup should not throw: \(error)")
        }

        // 验证清理后的数量
        let count = try await storage.getItemCount()
        XCTAssertLessThanOrEqual(count, 3, "Item count should be reduced")

        await storage.close()
    }

    // MARK: - Search Service Cleanup Tests

    // MARK: - Event Stream Cleanup Tests

    /// 测试服务停止后，事件监听任务可被取消并正常收尾（无需依赖 stream finish）
    func testEventStreamCleanup() async throws {
        let service = ClipboardServiceFactory.create(databasePath: Self.makeSharedInMemoryDatabasePath())

        // 启动服务
        try await service.start()

        // 创建一个监听事件的任务
        let eventTask = Task {
            var eventCount = 0
            for await _ in service.eventStream {
                eventCount += 1
                if eventCount >= 1 {
                    break
                }
            }
            return eventCount
        }

        // Give the listener a chance to subscribe.
        await Task.yield()

        // 停止服务（等待资源收尾）
        await service.stopAndWait()

        // 取消事件任务
        eventTask.cancel()

        // 验证任务可以正常结束
        let _ = await eventTask.value
    }

    private static func makeSharedInMemoryDatabasePath() -> String {
        "file:scopy_test_\(UUID().uuidString)?mode=memory&cache=shared"
    }

    // MARK: - Task Cancellation Tests

}
