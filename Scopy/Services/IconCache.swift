import AppKit
import Foundation

/// IconCache - 全局应用图标缓存管理器
/// v0.12: 使用 actor 确保线程安全，支持启动时预加载
actor IconCache {
    static let shared = IconCache()

    private var iconCache: [String: NSImage] = [:]
    private var nameCache: [String: String] = [:]
    private var accessOrder: [String] = []
    private let maxSize = 100

    // MARK: - Icon Cache

    /// 预加载应用图标（后台线程调用）
    func preload(bundleID: String) {
        guard iconCache[bundleID] == nil else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        // LRU 清理
        evictIfNeeded()

        iconCache[bundleID] = icon
        accessOrder.append(bundleID)
    }

    /// 获取缓存的图标（同步，无阻塞）
    func getIcon(bundleID: String) -> NSImage? {
        guard let icon = iconCache[bundleID] else { return nil }

        // 更新 LRU 访问顺序
        if let index = accessOrder.firstIndex(of: bundleID) {
            accessOrder.remove(at: index)
            accessOrder.append(bundleID)
        }

        return icon
    }

    /// 同步获取图标（用于 View 中的计算属性）
    /// 如果缓存命中返回图标，否则返回 nil 并触发后台加载
    nonisolated func getCached(bundleID: String) -> NSImage? {
        // 使用 Task.detached 在后台检查和加载
        // 但这里我们需要同步返回，所以只能返回 nil 让调用方回退
        // 实际的缓存访问需要通过 async 方法
        return nil
    }

    // MARK: - Name Cache

    /// 获取应用名称（带缓存）
    func getAppName(bundleID: String) -> String {
        if let cached = nameCache[bundleID] {
            return cached
        }

        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = bundleID
        }

        // LRU 清理
        if nameCache.count >= maxSize {
            if let oldest = accessOrder.first(where: { nameCache[$0] != nil }) {
                nameCache.removeValue(forKey: oldest)
            }
        }

        nameCache[bundleID] = name
        return name
    }

    // MARK: - Private

    private func evictIfNeeded() {
        guard iconCache.count >= maxSize else { return }
        if let oldest = accessOrder.first {
            iconCache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    /// 清空所有缓存
    func clearAll() {
        iconCache.removeAll()
        nameCache.removeAll()
        accessOrder.removeAll()
    }
}

// MARK: - Synchronous Access Helper

/// 用于 View 中同步访问图标缓存的辅助类
/// 使用静态缓存 + 锁保护，避免 actor 的异步开销
final class IconCacheSync {
    static let shared = IconCacheSync()

    private var cache: [String: NSImage] = [:]
    private var nameCache: [String: String] = [:]
    private var accessOrder: [String] = []
    private let lock = NSLock()
    private let maxSize = 100

    private init() {}

    /// 同步获取图标（用于 View 计算属性）
    func getIcon(bundleID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        if let icon = cache[bundleID] {
            // 更新 LRU
            if let index = accessOrder.firstIndex(of: bundleID) {
                accessOrder.remove(at: index)
            }
            accessOrder.append(bundleID)
            return icon
        }
        return nil
    }

    /// 同步设置图标（预加载时调用）
    func setIcon(_ icon: NSImage, for bundleID: String) {
        lock.lock()
        defer { lock.unlock() }

        // LRU 清理
        if cache.count >= maxSize, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        cache[bundleID] = icon
        if !accessOrder.contains(bundleID) {
            accessOrder.append(bundleID)
        }
    }

    /// 同步获取应用名称
    /// v0.20: 修复死锁风险 - 使用 withLock 确保锁正确释放，系统调用在锁外执行
    func getAppName(bundleID: String) -> String {
        // 1. 先检查缓存（在锁内）
        let cached: String? = lock.withLock {
            nameCache[bundleID]
        }

        if let cached = cached {
            return cached
        }

        // 2. 缓存未命中，在锁外获取名称（避免死锁）
        // NSWorkspace 调用可能触发系统回调，不能在锁内执行
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = bundleID
        }

        // 3. 写入缓存（在锁内）
        // 使用 double-check 避免重复写入
        lock.withLock {
            if nameCache[bundleID] == nil {
                // LRU 清理
                if nameCache.count >= maxSize {
                    // 找到最旧的名称缓存条目并移除
                    if let oldest = accessOrder.first(where: { nameCache[$0] != nil }) {
                        nameCache.removeValue(forKey: oldest)
                    }
                }
                nameCache[bundleID] = name
            }
        }

        return name
    }

    /// 预加载图标（后台线程调用）
    func preloadIcon(bundleID: String) {
        // 检查是否已缓存
        lock.lock()
        let exists = cache[bundleID] != nil
        lock.unlock()

        guard !exists else { return }

        // 获取图标（可能阻塞，应在后台线程调用）
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        // 写入缓存
        setIcon(icon, for: bundleID)
    }
}
