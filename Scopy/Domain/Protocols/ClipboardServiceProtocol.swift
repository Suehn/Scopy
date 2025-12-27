import Foundation

// MARK: - Service Protocol

/// 剪贴板服务协议 - 对应 v0.md 中的前后端接口设计
/// 后端只提供结构化数据和命令接口，不关心 UI
@MainActor
public protocol ClipboardServiceProtocol: AnyObject {
    // MARK: - Lifecycle

    /// 启动服务（真实服务需要初始化数据库、启动监控；Mock 服务可空实现）
    func start() async throws

    /// 停止服务（清理资源）
    func stop()

    /// 停止服务并等待清理完成（用于测试/退出路径，避免 sleep-based 等待）
    func stopAndWait() async

    // MARK: - Data Access

    /// 获取最近的剪贴板项
    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO]

    /// 搜索剪贴板历史
    func search(query: SearchRequest) async throws -> SearchResultPage

    /// 固定/取消固定项目
    func pin(itemID: UUID) async throws
    func unpin(itemID: UUID) async throws

    /// 删除项目
    func delete(itemID: UUID) async throws

    /// 清空历史
    func clearAll() async throws

    /// 复制到系统剪贴板
    func copyToClipboard(itemID: UUID) async throws

    /// 更新设置
    func updateSettings(_ settings: SettingsDTO) async throws

    /// 获取当前设置
    func getSettings() async throws -> SettingsDTO

    /// 获取存储统计
    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int)

    /// 获取详细的存储统计
    func getDetailedStorageStats() async throws -> StorageStatsDTO

    /// 获取图片原始数据（用于预览）
    func getImageData(itemID: UUID) async throws -> Data?

    /// 手动优化历史中的图片（pngquant）：压缩并覆盖原图，同时更新 DB 的 hash/size。
    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO

    /// 修复/同步：当用户在应用外部批量压缩了 `content/` 下的图片时，
    /// 数据库里的 `size_bytes` 可能仍是旧值，导致“内容估算”显示偏大与清理策略误判。
    /// 该方法会从磁盘读取外部图片的真实文件大小并写回 `size_bytes`。
    ///
    /// - Returns: 实际更新了多少条记录（size_bytes 发生变化的条目数）
    func syncExternalImageSizeBytesFromDisk() async throws -> Int

    /// 获取最近使用的 app 列表（用于过滤）
    func getRecentApps(limit: Int) async throws -> [String]

    /// 事件观察 - 新增条目、删除、设置变更等
    var eventStream: AsyncStream<ClipboardEvent> { get }
}

public extension ClipboardServiceProtocol {
    func stopAndWait() async {
        stop()
    }
}
