import AppKit
import Foundation

/// Mock 剪贴板服务 - 用于 UI 开发和测试
/// 符合 v0.md 的解耦验收标准: UI 可以在「后端 mock」模式下运行
@MainActor
final class MockClipboardService: ClipboardServiceProtocol {
    private struct MockConfig {
        let itemCount: Int
        let imageCount: Int
        let showThumbnails: Bool?
        let imagePreviewDelay: Double?
        let thumbnailSize: Int
        let textLength: Int

        static func load() -> MockConfig {
            let env = ProcessInfo.processInfo.environment
            let itemCount = max(0, parseInt(env["SCOPY_MOCK_ITEM_COUNT"]) ?? 100)
            let imageCount = max(0, parseInt(env["SCOPY_MOCK_IMAGE_COUNT"]) ?? 0)
            let showThumbnails = parseBool(env["SCOPY_MOCK_SHOW_THUMBNAILS"])
            let imagePreviewDelay = parseDouble(env["SCOPY_MOCK_IMAGE_PREVIEW_DELAY"])
            let thumbnailSize = max(16, parseInt(env["SCOPY_MOCK_THUMBNAIL_SIZE"]) ?? 64)
            let textLength = max(0, parseInt(env["SCOPY_MOCK_TEXT_LENGTH"]) ?? 0)

            return MockConfig(
                itemCount: itemCount,
                imageCount: imageCount,
                showThumbnails: showThumbnails,
                imagePreviewDelay: imagePreviewDelay,
                thumbnailSize: thumbnailSize,
                textLength: textLength
            )
        }

        private static func parseInt(_ value: String?) -> Int? {
            guard let value, !value.isEmpty else { return nil }
            return Int(value)
        }

        private static func parseDouble(_ value: String?) -> Double? {
            guard let value, !value.isEmpty else { return nil }
            return Double(value)
        }

        private static func parseBool(_ value: String?) -> Bool? {
            guard let value else { return nil }
            switch value.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
    }

    private static let config = MockConfig.load()

    private var items: [ClipboardItemDTO] = []
    private var settings: SettingsDTO
    private let eventQueue: AsyncBoundedQueue<ClipboardEvent>
    private let stream: AsyncStream<ClipboardEvent>

    var eventStream: AsyncStream<ClipboardEvent> {
        return stream
    }

    init() {
        let config = Self.config
        let queue = AsyncBoundedQueue<ClipboardEvent>(capacity: ScopyThresholds.clipboardEventStreamMaxBufferedItems)
        self.eventQueue = queue
        self.stream = AsyncStream(unfolding: { await queue.dequeue() })
        self.settings = Self.applySettingsOverrides(config: config)

        // 生成一些测试数据
        generateMockData(config: config)
    }

    deinit {
        Task { [eventQueue] in
            await eventQueue.finish()
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Mock 服务无需启动，空实现
    }

    func stop() {
    }

    func stopAndWait() async {
        await eventQueue.finish()
    }

    // MARK: - Private

    private func generateMockData(config: MockConfig) {
        let sampleTexts = [
            """
            # SCOPY_EXPORT_TEST_MARKDOWN

            交互图频谱基础（UI Export Test）

            - 这是一段用于 UI 导出验证的 Markdown 内容。
            - 公式：$E = mc^2$，以及 $\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$。

            ## Wide Table

            | very_long_header_col_01 | very_long_header_col_02 | very_long_header_col_03 | very_long_header_col_04 | very_long_header_col_05 | very_long_header_col_06 | very_long_header_col_07 | very_long_header_col_08 | very_long_header_col_09 | very_long_header_col_10 |
            | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
            | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
            | aaaaaaaaaaaaaaaaaaaaa | bbbbbbbbbbbbbbbbbbbbb | ccccccccccccccccccccc | ddddddddddddddddddddd | eeeeeeeeeeeeeeeeeeeee | fffffffffffffffffffff | ggggggggggggggggggggg | hhhhhhhhhhhhhhhhhhhhh | iiiiiiiiiiiiiiiiiiiii | jjjjjjjjjjjjjjjjjjjjj |

            ## Long Content

            这是第一段，用于确保导出高度超过一个视口，验证“全文导出”。

            这是第二段，包含一些中文与 English mixed content，确保排版稳定。

            这是第三段，继续拉长内容高度。重复几段以确保 snapshot 覆盖整页。

            这是第四段，继续拉长内容高度。重复几段以确保 snapshot 覆盖整页。

            这是第五段，继续拉长内容高度。重复几段以确保 snapshot 覆盖整页。
            """,
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
        let totalCount = max(sampleTexts.count, config.itemCount)
        let extraCount = max(0, totalCount - sampleTexts.count)
        let imageCount = min(config.imageCount, extraCount)
        let imagePaths = Self.prepareMockThumbnails(count: imageCount, size: config.thumbnailSize)
        let generatedText = Self.makeGeneratedText(length: config.textLength)
        let now = Date()

        for (index, text) in sampleTexts.enumerated() {
            let item = ClipboardItemDTO(
                id: UUID(),
                type: .text,
                contentHash: UUID().uuidString,
                plainText: text,
                appBundleID: apps[index % apps.count],
                createdAt: now.addingTimeInterval(Double(-index * 3600)),
                lastUsedAt: now.addingTimeInterval(Double(-index * 1800)),
                isPinned: index < 2,  // 前两个是固定的
                sizeBytes: text.utf8.count,
                thumbnailPath: nil,
                storageRef: nil
            )
            items.append(item)
        }

        // 添加更多测试数据以测试分页 / 滚动性能
        for i in 0..<extraCount {
            let index = sampleTexts.count + i
            if i < imageCount {
                let path = imagePaths[i]
                let item = ClipboardItemDTO(
                    id: UUID(),
                    type: .image,
                    contentHash: UUID().uuidString,
                    plainText: "",
                    appBundleID: apps[index % apps.count],
                    createdAt: now.addingTimeInterval(Double(-index * 3600)),
                    lastUsedAt: now.addingTimeInterval(Double(-index * 1800)),
                    isPinned: false,
                    sizeBytes: 0,
                    thumbnailPath: path,
                    storageRef: nil
                )
                items.append(item)
            } else {
                let item = ClipboardItemDTO(
                    id: UUID(),
                    type: .text,
                    contentHash: UUID().uuidString,
                    plainText: Self.makeItemText(index: index, fallback: generatedText),
                    appBundleID: apps[index % apps.count],
                    createdAt: now.addingTimeInterval(Double(-index * 3600)),
                    lastUsedAt: now.addingTimeInterval(Double(-index * 1800)),
                    isPinned: false,
                    sizeBytes: 100,
                    thumbnailPath: nil,
                    storageRef: nil
                )
                items.append(item)
            }
        }
    }

    private static func applySettingsOverrides(config: MockConfig) -> SettingsDTO {
        var settings = SettingsDTO.default
        if let showThumbnails = config.showThumbnails {
            settings.showImageThumbnails = showThumbnails
        }
        if let imagePreviewDelay = config.imagePreviewDelay {
            settings.imagePreviewDelay = imagePreviewDelay
        }
        return settings
    }

    private static func prepareMockThumbnails(count: Int, size: Int) -> [String] {
        guard count > 0 else { return [] }
        let directory = URL(fileURLWithPath: "/tmp/scopy_mock_thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        var paths: [String] = []
        paths.reserveCapacity(count)

        for index in 0..<count {
            let url = directory.appendingPathComponent("thumb_\(size)_\(index).png")
            if !FileManager.default.fileExists(atPath: url.path) {
                if let data = makeThumbnailData(size: size, seed: index) {
                    try? data.write(to: url, options: .atomic)
                }
            }
            paths.append(url.path)
        }

        return paths
    }

    private static func makeThumbnailData(size: Int, seed: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let hue = CGFloat((seed % 360)) / 360.0
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedHue: hue, saturation: 0.4, brightness: 0.9, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func makeGeneratedText(length: Int) -> String? {
        guard length > 0 else { return nil }
        let seed = "word word word "
        let repeats = max(1, length / seed.count + 1)
        let text = String(repeating: seed, count: repeats)
        return String(text.prefix(length))
    }

    private static func makeItemText(index: Int, fallback: String?) -> String {
        if let fallback {
            return fallback
        }
        return "Test item #\(index) - Some random text content for testing pagination and scrolling behavior."
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
                case .fuzzy, .fuzzyPlus:
                    // 简单的模糊匹配（Mock 服务不区分 fuzzy 和 fuzzyPlus）
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
            await yieldEvent(.itemPinned(itemID))
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
            await yieldEvent(.itemUnpinned(itemID))
        }
    }

    func delete(itemID: UUID) async throws {
        items.removeAll { $0.id == itemID }
        await yieldEvent(.itemDeleted(itemID))
    }

    func clearAll() async throws {
        let pinnedItems = items.filter { $0.isPinned }
        items = pinnedItems
        await yieldEvent(.itemsCleared(keepPinned: true))
    }

    func copyToClipboard(itemID: UUID) async throws {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        // 在真实实现中，这里会复制到系统剪贴板
        ScopyLog.app.info("Copied to clipboard: \(String(item.plainText.prefix(50)), privacy: .private)...")
    }

    func updateSettings(_ newSettings: SettingsDTO) async throws {
        settings = newSettings
        await yieldEvent(.settingsChanged)
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
            thumbnailSizeBytes: 0,
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
        Task { [eventQueue] in
            await eventQueue.enqueue(.newItem(item))
        }
    }

    private func yieldEvent(_ event: ClipboardEvent) async {
        await eventQueue.enqueue(event)
    }
}
