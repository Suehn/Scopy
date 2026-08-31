import AppKit
import CryptoKit
import Foundation

/// Mock 剪贴板服务 - 用于 UI 开发和测试
/// 符合 v0.md 的解耦验收标准: UI 可以在「后端 mock」模式下运行
@MainActor
final class MockClipboardService: ClipboardServiceProtocol {
    private struct MockConfig {
        let datasetID: String?
        let itemCount: Int
        let imageCount: Int
        let showThumbnails: Bool?
        let imagePreviewDelay: Double?
        let thumbnailSize: Int
        let textLength: Int
        let historyListIntegrationNamespace: String?
        let noteUpdateDelayMilliseconds: Int?

        static func load() -> MockConfig {
            let env = ProcessInfo.processInfo.environment
            let datasetID = normalized(env["SCOPY_MOCK_DATASET_ID"])
            let itemCount = max(0, parseInt(env["SCOPY_MOCK_ITEM_COUNT"]) ?? 100)
            let imageCount = max(0, parseInt(env["SCOPY_MOCK_IMAGE_COUNT"]) ?? 0)
            let showThumbnails = parseBool(env["SCOPY_MOCK_SHOW_THUMBNAILS"])
            let imagePreviewDelay = parseDouble(env["SCOPY_MOCK_IMAGE_PREVIEW_DELAY"])
            let thumbnailSize = max(16, parseInt(env["SCOPY_MOCK_THUMBNAIL_SIZE"]) ?? 64)
            let textLength = max(0, parseInt(env["SCOPY_MOCK_TEXT_LENGTH"]) ?? 0)
            let historyListIntegrationNamespace = historyListIntegrationNamespace(
                environment: env,
                arguments: ProcessInfo.processInfo.arguments
            )
            let noteUpdateDelayMilliseconds = historyListIntegrationNamespace.map { _ in
                MockClipboardService.boundedUITestNoteDelayMilliseconds(
                    env["SCOPY_MOCK_UPDATE_NOTE_DELAY_MS"]
                )
            }

            return MockConfig(
                datasetID: datasetID,
                itemCount: itemCount,
                imageCount: imageCount,
                showThumbnails: showThumbnails,
                imagePreviewDelay: imagePreviewDelay,
                thumbnailSize: thumbnailSize,
                textLength: textLength,
                historyListIntegrationNamespace: historyListIntegrationNamespace,
                noteUpdateDelayMilliseconds: noteUpdateDelayMilliseconds
            )
        }

        private static func historyListIntegrationNamespace(
            environment: [String: String],
            arguments: [String]
        ) -> String? {
            guard arguments.contains("--uitesting"),
                  arguments.contains("--history-list-retained-interaction"),
                  environment["SCOPY_UITEST_HISTORY_LIST_INTEGRATION"] == "1"
            else { return nil }
            return normalized(environment["SCOPY_UITEST_HISTORY_LIST_NAMESPACE"])
        }

        private static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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
    static let fixedWarmTextDatasetID = "fixed-warm-text-v1"
    static let fixedWarmTextItemCount = 50
    static let fixedWarmTextLength = 4_096
    static let fixedWarmTextPinnedCount = 2
    static let historyListIntegrationDatasetID = "history-list-retained-interaction-v1"
    static let historyListIntegrationItemCount = 50
    static let historyListIntegrationImageTargetID = UUID(
        uuidString: "53504359-1001-4000-8000-000000000001"
    )!
    static let historyListIntegrationFileTargetID = UUID(
        uuidString: "53504359-1001-4000-8000-000000000002"
    )!

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
        if config.historyListIntegrationNamespace != nil,
           config.datasetID == Self.historyListIntegrationDatasetID {
            items = Self.makeHistoryListIntegrationDataset()
            return
        }

        if config.datasetID == Self.fixedWarmTextDatasetID {
            items = Self.makeFixedWarmTextDataset()
            return
        }

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
                note: nil,
                appBundleID: apps[index % apps.count],
                createdAt: now.addingTimeInterval(Double(-index * 3600)),
                lastUsedAt: now.addingTimeInterval(Double(-index * 1800)),
                isPinned: index < 2,  // 前两个是固定的
                sizeBytes: text.utf8.count,
                fileSizeBytes: nil,
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
                    note: nil,
                    appBundleID: apps[index % apps.count],
                    createdAt: now.addingTimeInterval(Double(-index * 3600)),
                    lastUsedAt: now.addingTimeInterval(Double(-index * 1800)),
                    isPinned: false,
                    sizeBytes: 0,
                    fileSizeBytes: nil,
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
                    note: nil,
                    appBundleID: apps[index % apps.count],
                    createdAt: now.addingTimeInterval(Double(-index * 3600)),
                    lastUsedAt: now.addingTimeInterval(Double(-index * 1800)),
                    isPinned: false,
                    sizeBytes: 100,
                    fileSizeBytes: nil,
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

    static func makeFixedWarmTextDataset() -> [ClipboardItemDTO] {
        let referenceTime = Date(timeIntervalSince1970: 1_700_000_000)
        var result: [ClipboardItemDTO] = []
        result.reserveCapacity(fixedWarmTextItemCount)

        for index in 0..<fixedWarmTextItemCount {
            let plainText = makeFixedWarmTextPayload(index: index)
            let lastUsedAt = referenceTime.addingTimeInterval(Double(-index * 60))
            result.append(
                ClipboardItemDTO(
                    id: fixedWarmTextUUID(index: index),
                    type: .text,
                    contentHash: sha256Hex(plainText),
                    plainText: plainText,
                    note: nil,
                    appBundleID: "com.scopy.profile.fixture",
                    createdAt: lastUsedAt.addingTimeInterval(-30),
                    lastUsedAt: lastUsedAt,
                    isPinned: index < fixedWarmTextPinnedCount,
                    sizeBytes: plainText.utf8.count,
                    fileSizeBytes: nil,
                    thumbnailPath: nil,
                    storageRef: nil
                )
            )
        }

        return result
    }

    static func makeHistoryListIntegrationDataset() -> [ClipboardItemDTO] {
        let referenceTime = Date(timeIntervalSince1970: 1_710_000_000)
        var result: [ClipboardItemDTO] = [
            ClipboardItemDTO(
                id: historyListIntegrationImageTargetID,
                type: .image,
                contentHash: sha256Hex("history-list-image-target"),
                plainText: "640x480",
                note: nil,
                appBundleID: "com.scopy.uitest.fixture",
                createdAt: referenceTime.addingTimeInterval(-30),
                lastUsedAt: referenceTime,
                isPinned: false,
                sizeBytes: 4_096,
                fileSizeBytes: nil,
                thumbnailPath: nil,
                storageRef: nil
            ),
            ClipboardItemDTO(
                id: historyListIntegrationFileTargetID,
                type: .file,
                contentHash: sha256Hex("history-list-file-target"),
                plainText: "/tmp/scopy-history-list-note-target.txt",
                note: nil,
                appBundleID: "com.scopy.uitest.fixture",
                createdAt: referenceTime.addingTimeInterval(-90),
                lastUsedAt: referenceTime.addingTimeInterval(-60),
                isPinned: false,
                sizeBytes: 1_024,
                fileSizeBytes: 1_024,
                thumbnailPath: nil,
                storageRef: nil
            )
        ]
        result.reserveCapacity(historyListIntegrationItemCount)

        for index in 2..<historyListIntegrationItemCount {
            let plainText = String(format: "History list integration filler row %02d", index)
            let lastUsedAt = referenceTime.addingTimeInterval(Double(-index * 60))
            result.append(
                ClipboardItemDTO(
                    id: historyListIntegrationUUID(index: index),
                    type: .text,
                    contentHash: sha256Hex(plainText),
                    plainText: plainText,
                    note: nil,
                    appBundleID: "com.scopy.uitest.fixture",
                    createdAt: lastUsedAt.addingTimeInterval(-30),
                    lastUsedAt: lastUsedAt,
                    isPinned: false,
                    sizeBytes: plainText.utf8.count,
                    fileSizeBytes: nil,
                    thumbnailPath: nil,
                    storageRef: nil
                )
            )
        }

        return result
    }

    nonisolated static func boundedUITestNoteDelayMilliseconds(_ rawValue: String?) -> Int {
        let requested = rawValue.flatMap(Int.init) ?? 700
        return min(2_000, max(600, requested))
    }

    private static func makeFixedWarmTextPayload(index: Int) -> String {
        let seed = String(format: "scopy fixed row %02d word word word ", index)
        let repeats = max(1, fixedWarmTextLength / seed.utf8.count + 1)
        return String(String(repeating: seed, count: repeats).prefix(fixedWarmTextLength))
    }

    private static func fixedWarmTextUUID(index: Int) -> UUID {
        let rawValue = String(format: "53504359-0001-4000-8000-%012X", index)
        guard let value = UUID(uuidString: rawValue) else {
            preconditionFailure("Invalid fixed warm-text UUID: \(rawValue)")
        }
        return value
    }

    private static func historyListIntegrationUUID(index: Int) -> UUID {
        let rawValue = String(format: "53504359-1001-4000-8000-%012X", index + 1)
        guard let value = UUID(uuidString: rawValue) else {
            preconditionFailure("Invalid history-list integration UUID: \(rawValue)")
        }
        return value
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        let sortedItems = items.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let start = min(offset, sortedItems.count)
        let end = min(offset + limit, sortedItems.count)
        return Array(sortedItems[start..<end])
    }

    func fetchPinned() async throws -> [ClipboardItemDTO] {
        try await Task.sleep(nanoseconds: 50_000_000)
        return items
            .filter(\.isPinned)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func fetchRecentUnpinned(limit: Int, offset: Int) async throws -> [ClipboardItemDTO] {
        try await Task.sleep(nanoseconds: 50_000_000)
        let sortedItems = items
            .filter { !$0.isPinned }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        let start = min(offset, sortedItems.count)
        let end = min(offset + limit, sortedItems.count)
        return Array(sortedItems[start..<end])
    }

    func search(query: SearchRequest) async throws -> SearchResultPage {
        // 模拟搜索延迟
        try await Task.sleep(nanoseconds: 30_000_000)  // 30ms

        let filtered: [ClipboardItemDTO]
        let matcher = try SearchMatchContextBuilder.prepare(request: query, coverage: .complete)

        if !query.hasSemanticQuery {
            filtered = items
        } else {
            filtered = try items.filter { item in
                try matcher.makeContext(
                    plainText: item.plainText,
                    note: item.note
                ) != nil
            }
        }

        let total = filtered.count
        let start = min(query.offset, total)
        let end = min(query.offset + query.limit, total)
        let pageItems = Array(filtered[start..<end])

        let hits = try pageItems.map { item in
            SearchResultHit(
                item: item,
                matchContext: try matcher.makeContext(
                    plainText: item.plainText,
                    note: item.note
                )
            )
        }

        return SearchResultPage(
            hits: hits,
            total: total,
            hasMore: end < total,
            coverage: .complete
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
                note: item.note,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: true,
                sizeBytes: item.sizeBytes,
                fileSizeBytes: item.fileSizeBytes,
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
                note: item.note,
                appBundleID: item.appBundleID,
                createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt,
                isPinned: false,
                sizeBytes: item.sizeBytes,
                fileSizeBytes: item.fileSizeBytes,
                thumbnailPath: item.thumbnailPath,
                storageRef: item.storageRef
            )
            await yieldEvent(.itemUnpinned(itemID))
        }
    }

    func updateNote(itemID: UUID, note: String?) async throws {
        if let delayMilliseconds = Self.config.noteUpdateDelayMilliseconds {
            try await Task.sleep(
                nanoseconds: UInt64(delayMilliseconds) * 1_000_000
            )
        }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let item = items[index]
        let updated = ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: item.contentHash,
            plainText: item.plainText,
            note: normalized,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: item.sizeBytes,
            fileSizeBytes: item.fileSizeBytes,
            thumbnailPath: item.thumbnailPath,
            storageRef: item.storageRef
        )
        items[index] = updated
        postHistoryListIntegrationPersistedNoteIfNeeded(itemID: itemID, note: normalized)
        await yieldEvent(.itemContentUpdated(updated))
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

    func copyToClipboardOptimizedForCodex(itemID: UUID) async throws {
        try await copyToClipboard(itemID: itemID)
    }

    func fileURLs(itemID _: UUID) async throws -> [URL] {
        []
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

    func optimizeImage(itemID: UUID) async throws -> ImageOptimizationOutcomeDTO {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: 0, optimizedBytes: 0)
        }
        let item = items[index]
        guard item.type == .image else {
            return ImageOptimizationOutcomeDTO(result: .noChange, originalBytes: item.sizeBytes, optimizedBytes: item.sizeBytes)
        }

        let original = max(0, item.sizeBytes)
        let optimized = max(0, original - max(1, original / 4))
        let updated = ClipboardItemDTO(
            id: item.id,
            type: item.type,
            contentHash: UUID().uuidString,
            plainText: item.plainText,
            note: item.note,
            appBundleID: item.appBundleID,
            createdAt: item.createdAt,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned,
            sizeBytes: optimized,
            fileSizeBytes: item.fileSizeBytes,
            thumbnailPath: item.thumbnailPath,
            storageRef: item.storageRef
        )
        items[index] = updated
        await yieldEvent(.itemContentUpdated(updated))
        return ImageOptimizationOutcomeDTO(
            result: .optimized,
            originalBytes: original,
            optimizedBytes: optimized,
            resultingContentHash: updated.contentHash
        )
    }

    func syncExternalImageSizeBytesFromDisk() async throws -> Int {
        // Mock 环境不接触真实文件系统，返回 0 表示无更新。
        0
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
            note: nil,
            appBundleID: "com.apple.dt.Xcode",
            createdAt: Date(),
            lastUsedAt: Date(),
            isPinned: false,
            sizeBytes: text.utf8.count,
            fileSizeBytes: nil,
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

    private func postHistoryListIntegrationPersistedNoteIfNeeded(
        itemID: UUID,
        note: String?
    ) {
        guard let namespace = Self.config.historyListIntegrationNamespace,
              itemID == Self.historyListIntegrationFileTargetID else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(
                "org.scopy.uitest.history-list.\(namespace).mock-note-persisted"
            ),
            object: itemID.uuidString,
            userInfo: ["note": note ?? ""],
            deliverImmediately: true
        )
    }
}
