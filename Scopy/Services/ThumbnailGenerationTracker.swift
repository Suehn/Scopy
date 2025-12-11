import Foundation

/// v0.23: 缩略图生成状态跟踪器
/// 使用 actor 确保线程安全，替代 nonisolated(unsafe) + NSLock 方案
actor ThumbnailGenerationTracker {
    static let shared = ThumbnailGenerationTracker()

    private var inProgress = Set<String>()

    private init() {}

    /// 尝试标记为正在生成
    /// - Returns: true 如果成功标记（之前未在生成），false 如果已在生成中
    func tryMarkInProgress(_ contentHash: String) -> Bool {
        if inProgress.contains(contentHash) {
            return false
        }
        inProgress.insert(contentHash)
        return true
    }

    /// 标记生成完成
    func markCompleted(_ contentHash: String) {
        inProgress.remove(contentHash)
    }

    /// 检查是否正在生成（用于调试）
    func isInProgress(_ contentHash: String) -> Bool {
        inProgress.contains(contentHash)
    }

    /// 获取当前正在生成的数量（用于调试）
    var count: Int {
        inProgress.count
    }
}
