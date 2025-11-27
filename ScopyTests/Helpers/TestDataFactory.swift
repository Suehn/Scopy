import Foundation
@testable import Scopy

/// 测试数据工厂
/// 提供统一的测试数据生成方法
enum TestDataFactory {

    // MARK: - ClipboardContent Generation

    /// 创建文本类型的剪贴板内容
    static func makeTextContent(
        _ text: String,
        appBundleID: String = "com.test.app"
    ) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            rawData: nil,
            appBundleID: appBundleID,
            contentHash: computeHash(text),
            sizeBytes: text.utf8.count
        )
    }

    /// 创建图片类型的剪贴板内容
    static func makeImageContent(
        width: Int = 100,
        height: Int = 100,
        appBundleID: String = "com.test.app"
    ) -> ClipboardMonitor.ClipboardContent {
        // Generate fake image data
        let dataSize = width * height * 4 // RGBA
        let data = Data(repeating: 0xFF, count: dataSize)
        let hash = "image_\(width)x\(height)_\(UUID().uuidString.prefix(8))"

        return ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "",
            rawData: data,
            appBundleID: appBundleID,
            contentHash: hash,
            sizeBytes: dataSize
        )
    }

    /// 创建文件类型的剪贴板内容
    static func makeFileContent(
        path: String = "/tmp/test.txt",
        appBundleID: String = "com.apple.finder"
    ) -> ClipboardMonitor.ClipboardContent {
        let url = URL(fileURLWithPath: path)
        let hash = "file_\(path.hashValue)"

        return ClipboardMonitor.ClipboardContent(
            type: .file,
            plainText: url.absoluteString,
            rawData: nil,
            appBundleID: appBundleID,
            contentHash: hash,
            sizeBytes: 0
        )
    }

    // MARK: - ClipboardItemDTO Generation

    /// 创建测试用的 ClipboardItemDTO
    static func makeItem(
        id: UUID = UUID(),
        plainText: String,
        appBundleID: String = "com.test.app",
        isPinned: Bool = false,
        createdAt: Date = Date()
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: .text,
            contentHash: computeHash(plainText),
            plainText: plainText,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: createdAt,
            isPinned: isPinned,
            sizeBytes: plainText.utf8.count
        )
    }

    /// 批量创建测试项目
    static func makeItems(
        count: Int,
        prefix: String = "Test item",
        appBundleID: String = "com.test.app"
    ) -> [ClipboardItemDTO] {
        (0..<count).map { i in
            makeItem(
                plainText: "\(prefix) \(i)",
                appBundleID: appBundleID,
                createdAt: Date().addingTimeInterval(Double(-i))
            )
        }
    }

    /// 创建包含各种类型的混合测试数据
    static func makeMixedItems(count: Int) -> [ClipboardItemDTO] {
        let apps: [String] = ["com.apple.Safari", "com.apple.mail", "com.apple.Xcode", "com.apple.Notes"]
        let prefixes: [String] = ["Hello", "World", "Test", "Sample", "Demo"]

        var result: [ClipboardItemDTO] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let text = "\(prefixes[i % prefixes.count]) item \(i)"
            let app = apps[i % apps.count]
            let pinned = (i % 10 == 0)
            let date = Date().addingTimeInterval(Double(-i * 60))

            let item = makeItem(
                plainText: text,
                appBundleID: app,
                isPinned: pinned,
                createdAt: date
            )
            result.append(item)
        }

        return result
    }

    // MARK: - SearchRequest Generation

    /// 创建搜索请求
    static func makeSearchRequest(
        query: String,
        mode: SearchMode = .fuzzy,
        appFilter: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) -> SearchRequest {
        SearchRequest(
            query: query,
            mode: mode,
            appFilter: appFilter,
            limit: limit,
            offset: offset
        )
    }

    // MARK: - Helpers

    private static func computeHash(_ text: String) -> String {
        String(text.hashValue)
    }
}

// MARK: - Test Data Scenarios

extension TestDataFactory {

    /// 创建搜索测试场景数据
    struct SearchTestScenario {
        let items: [ClipboardItemDTO]
        let query: String
        let expectedCount: Int
        let description: String
    }

    /// 获取预定义的搜索测试场景
    static func searchScenarios() -> [SearchTestScenario] {
        [
            SearchTestScenario(
                items: makeItems(count: 100, prefix: "Hello World"),
                query: "Hello",
                expectedCount: 100,
                description: "Simple prefix match"
            ),
            SearchTestScenario(
                items: makeItems(count: 50, prefix: "Test") + makeItems(count: 50, prefix: "Other"),
                query: "Test",
                expectedCount: 50,
                description: "Partial match in mixed data"
            ),
            SearchTestScenario(
                items: makeItems(count: 100, prefix: "Sample"),
                query: "xyz",
                expectedCount: 0,
                description: "No match"
            )
        ]
    }

    /// 创建性能测试数据
    static func performanceTestData(
        scale: PerformanceScale
    ) -> [ClipboardMonitor.ClipboardContent] {
        let count = scale.itemCount
        return (0..<count).map { i in
            makeTextContent("Performance test item \(i) with additional content for realistic size")
        }
    }

    enum PerformanceScale {
        case small      // 1,000 items
        case medium     // 5,000 items
        case large      // 10,000 items

        var itemCount: Int {
            switch self {
            case .small: return 1_000
            case .medium: return 5_000
            case .large: return 10_000
            }
        }
    }
}
