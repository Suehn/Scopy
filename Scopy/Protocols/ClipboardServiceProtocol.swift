import Foundation

// MARK: - Data Transfer Objects (DTOs)

/// 搜索模式 - 对应 v0.md 中的 SearchMode
enum SearchMode: String, Sendable {
    case exact
    case fuzzy
    case regex
}

/// 剪贴板项类型
enum ClipboardItemType: String, Sendable {
    case text
    case rtf
    case html
    case image
    case file
    case other
}

/// 剪贴板项 DTO - 对应 v0.md 中的 ClipboardItem
struct ClipboardItemDTO: Identifiable, Sendable, Hashable {
    let id: UUID
    let type: ClipboardItemType
    let contentHash: String
    let plainText: String
    let appBundleID: String?
    let createdAt: Date
    let lastUsedAt: Date
    let isPinned: Bool
    let sizeBytes: Int

    // 用于 UI 显示
    var title: String { plainText.isEmpty ? "(No text)" : String(plainText.prefix(100)) }
}

/// 搜索请求 - 对应 v0.md 中的 SearchRequest
struct SearchRequest: Sendable {
    let query: String
    let mode: SearchMode
    let appFilter: String?
    let typeFilter: ClipboardItemType?
    let limit: Int
    let offset: Int

    init(
        query: String,
        mode: SearchMode = .fuzzy,
        appFilter: String? = nil,
        typeFilter: ClipboardItemType? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.query = query
        self.mode = mode
        self.appFilter = appFilter
        self.typeFilter = typeFilter
        self.limit = limit
        self.offset = offset
    }
}

/// 搜索结果页 - 对应 v0.md 中的 SearchResultPage
struct SearchResultPage: Sendable {
    let items: [ClipboardItemDTO]
    let total: Int
    let hasMore: Bool
}

/// 剪贴板事件 - 对应 v0.md 中的 ClipboardEvent
enum ClipboardEvent: Sendable {
    case newItem(ClipboardItemDTO)
    case itemDeleted(UUID)
    case itemPinned(UUID)
    case itemUnpinned(UUID)
    case settingsChanged
}

/// 设置 DTO
struct SettingsDTO: Sendable {
    var maxItems: Int
    var maxStorageMB: Int
    var saveImages: Bool
    var saveFiles: Bool

    static let `default` = SettingsDTO(
        maxItems: 10000,
        maxStorageMB: 200,
        saveImages: true,
        saveFiles: true
    )
}

// MARK: - Service Protocol

/// 剪贴板服务协议 - 对应 v0.md 中的前后端接口设计
/// 后端只提供结构化数据和命令接口，不关心 UI
@MainActor
protocol ClipboardServiceProtocol: AnyObject {
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

    /// 事件观察 - 新增条目、删除、设置变更等
    var eventStream: AsyncStream<ClipboardEvent> { get }
}
