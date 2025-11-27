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
    let thumbnailPath: String?  // 缩略图路径 (v0.8)
    let storageRef: String?     // 外部存储路径 (v0.8 - 用于原图预览)

    // 用于 UI 显示
    var title: String {
        switch type {
        case .file:
            // 提取文件名，多文件显示 "文件名 + N more"
            let paths = plainText.components(separatedBy: "\n").filter { !$0.isEmpty }
            let fileCount = paths.count
            let firstName = URL(fileURLWithPath: paths.first ?? "").lastPathComponent
            if fileCount <= 1 {
                return firstName.isEmpty ? plainText : firstName
            } else {
                return "\(firstName) + \(fileCount - 1) more"
            }
        case .image:
            // 保持 "[Image: X KB]" 格式
            return plainText
        default:
            return plainText.isEmpty ? "(No text)" : String(plainText.prefix(100))
        }
    }
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
    case itemUpdated(ClipboardItemDTO)  // 用于置顶更新的条目
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
    var defaultSearchMode: SearchMode
    var hotkeyKeyCode: UInt32
    var hotkeyModifiers: UInt32
    // 缩略图设置 (v0.8)
    var showImageThumbnails: Bool
    var thumbnailHeight: Int
    var imagePreviewDelay: Double  // 悬浮预览延迟（秒）

    static let `default` = SettingsDTO(
        maxItems: 10000,
        maxStorageMB: 200,
        saveImages: true,
        saveFiles: true,
        defaultSearchMode: .fuzzy,
        hotkeyKeyCode: 8,  // kVK_ANSI_C = 8
        hotkeyModifiers: 0x0300,  // shiftKey (0x0200) | cmdKey (0x0100)
        showImageThumbnails: true,
        thumbnailHeight: 40,
        imagePreviewDelay: 1.0
    )
}

/// 存储统计详情 DTO
struct StorageStatsDTO: Sendable {
    let itemCount: Int
    let databaseSizeBytes: Int
    let externalStorageSizeBytes: Int
    let totalSizeBytes: Int
    let databasePath: String

    var databaseSizeText: String {
        formatBytes(databaseSizeBytes)
    }

    var externalStorageSizeText: String {
        formatBytes(externalStorageSizeBytes)
    }

    var totalSizeText: String {
        formatBytes(totalSizeBytes)
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        } else {
            return String(format: "%.1f MB", kb / 1024)
        }
    }
}

// MARK: - Service Protocol

/// 剪贴板服务协议 - 对应 v0.md 中的前后端接口设计
/// 后端只提供结构化数据和命令接口，不关心 UI
@MainActor
protocol ClipboardServiceProtocol: AnyObject {
    // MARK: - Lifecycle

    /// 启动服务（真实服务需要初始化数据库、启动监控；Mock 服务可空实现）
    func start() async throws

    /// 停止服务（清理资源）
    func stop()

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

    /// 获取最近使用的 app 列表（用于过滤）
    func getRecentApps(limit: Int) async throws -> [String]

    /// 事件观察 - 新增条目、删除、设置变更等
    var eventStream: AsyncStream<ClipboardEvent> { get }
}
