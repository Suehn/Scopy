import Foundation

/// NSLock 扩展 - 提供安全的锁操作
/// v0.17.1: 统一锁策略，与 Swift 标准库保持一致
extension NSLock {
    /// 安全执行闭包，自动管理锁的获取和释放
    /// 与 Swift 标准库的 withLock 保持一致
    ///
    /// 使用示例:
    /// ```swift
    /// let result = lock.withLock {
    ///     // 受保护的代码
    ///     return someValue
    /// }
    /// ```
    ///
    /// - Parameter body: 需要在锁保护下执行的闭包
    /// - Returns: 闭包的返回值
    /// - Throws: 闭包抛出的任何错误
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
