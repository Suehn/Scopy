import Foundation

/// Mock 剪贴板服务 - 用于 UI 开发和测试
/// 符合 v0.md 的解耦验收标准: UI 可以在「后端 mock」模式下运行
@MainActor
final class MockClipboardService: ClipboardServiceProtocol {
    private var items: [ClipboardItemDTO] = []
    private var settings: SettingsDTO = .default
    private var eventContinuation: AsyncStream<ClipboardEvent>.Continuation?

    var eventStream: AsyncStream<ClipboardEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    init() {
        // 生成一些测试数据
        generateMockData()
    }

    private func generateMockData() {
        let sampleTexts = [
            "Hello, World! This is a sample clipboard item.",
            "https://github.com/example/repo",
            "SELECT * FROM users WHERE id = 1;",
            "func greet(name: String) -> String { return \"Hello, \\(name)!\" }",
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
            "npm install --save-dev typescript",
            "git commit -m \"Initial commit\"",
            "export PATH=$PATH:/usr/local/bin",
            "The quick brown fox jumps over the lazy dog.",
            "{ \"name\": \"John\", \"age\": 30 }",
        ]

        let apps = ["com.apple.Safari", "com.apple.Terminal", "com.microsoft.VSCode", "com.apple.finder", nil]

        for (index, text) in sampleTexts.enumerated() {
            let item = ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: UUID().uuidString,
                plainText: text,
                appBundleID: apps[index % apps.count],
                createdAt: Date().addingTimeInterval(Double(-index * 3600)),
                lastUsedAt: Date().addingTimeInterval(Double(-index * 1800)),
                isPinned: index < 2,  // 前两个是固定的
                sizeBytes: text.utf8.count,
                thumbnailPath: nil,
                storageRef: nil
            )
            items.append(item)
        }

        // 添加更多测试数据以测试分页
        for i in 10..<100 {
            let item = ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: UUID().uuidString,
                plainText: "Test item #\(i) - Some random text content for testing pagination and scrolling behavior.",
                appBundleID: apps[i % apps.count],
                createdAt: Date().addingTimeInterval(Double(-i * 3600)),
                lastUsedAt: Date().addingTimeInterval(Double(-i * 1800)),
                isPinned: false,
                sizeBytes: 100,
                thumbnailPath: nil,
                storageRef: nil
            )
            items.append(item)
        }
    }

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        let sortedItems = items.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let start = min(offset, sortedItems.count)
        let end = min(offset + limit, sortedItems.count)
        return Array(sortedItems[start..<end])
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        // 模拟搜索延迟
        try await Task.sleep(nanoseconds: 30_000_000)  // 30ms

        let filtered: [ClipboardItemDTO]
        if query.query.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { item in
                switch query.mode {
                case .exact:
                    return item.plainText.localizedCaseInsensitiveContains(query.query)
                case .fuzzy:
                    // 简单的模糊匹配
                    return item.plainText.localizedCaseInsensitiveContains(query.query)
                case .regex:
                    if let regex = try? NSRegularExpression(pattern: query.query, options: .caseInsensitive) {
                        let range = NSRange(item.plainText.startIndex..., in: item.plainText)
                        return regex.firstMatch(in: item.plainText, range: range) != nil
                    }
                    return false
                }
            }
        }

        let total = filtered.count
        let start = min(query.offset, total)
        let end = min(query.offset + query.limit, total)
        let pageItems = Array(filtered[start..<end])

        return SearchResultPage(
            items: pageItems,
            total: total,
            hasMore: end < total
        )
    }

    func pin(itemID: UUID) async throws {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id,
                type: item.type,
                contentHash: item.contentHash,
                plainText: item.plainText,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: true,
                sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath,
                storageRef: item.storageRef
            )
            eventContinuation?.yield(.itemPinned(itemID))
        }
    }

    func unpin(itemID: UUID) async throws {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            let item = items[index]
            items[index] = ClipboardItemDTO(
                id: item.id,
                type: item.type,
                contentHash: item.contentHash,
                plainText: item.plainText,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: false,
                sizeBytes: item.sizeBytes,
                thumbnailPath: item.thumbnailPath,
                storageRef: item.storageRef
            )
            eventContinuation?.yield(.itemUnpinned(itemID))
        }
    }

    func delete(itemID: UUID) async throws {
        items.removeAll { $0.id == itemID }
        eventContinuation?.yield(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        let pinnedItems = items.filter { $0.isPinned }
        items = pinnedItems
        eventContinuation?.yield(.settingsChanged)
    }

    func copyToClipboard(itemID: UUID) async throws {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        // 在真实实现中，这里会复制到系统剪贴板
        print("Copied to clipboard: \(item.plainText.prefix(50))...")
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        settings = newSettings
        eventContinuation?.yield(.settingsChanged)
    }

    func getSettings() async throws -> SettingsDTO {
        return settings
    }

    func getStorageStats() async throws -> (itemCount: Int, sizeBytes: Int) {
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        return (items.count, totalBytes)
    }

    func getDetailedStorageStats() async throws -> StorageStatsDTO {
        let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
        return StorageStatsDTO(
            itemCount: items.count,
            databaseSizeBytes: totalBytes,
            externalStorageSizeBytes: 0,
            totalSizeBytes: totalBytes,
            databasePath: "~/Library/Application Support/Scopy/"
        )
    }

    func getImageData(itemID: UUID) async throws -> Data? {
        // Mock 服务不存储实际图片数据
        return nil
    }

    func getRecentApps(limit: Int) async throws -> [String] {
        // 返回 mock 数据中的 app 列表
        let apps = Set(items.compactMap { $0.appBundleID })
        return Array(apps.prefix(limit))
    }

    // 模拟添加新剪贴板项
    func simulateNewClipboardItem(_ text: String) {
        let item = ClipboardItemDTO(
            id: UUID(),
            type: .text,
            contentHash: UUID().uuidString,
            plainText: text,
            appBundleID: "com.apple.dt.Xcode",
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: text.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
        items.insert(item, at: 0)
        eventContinuation?.yield(.newItem(item))
    }
}
