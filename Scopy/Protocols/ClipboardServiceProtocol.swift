import Foundation

// MARK: - Data Transfer Objects (DTOs)

/// 搜索模式 - 对应 v0.md 中的 SearchMode
enum SearchMode: String, Sendable, CaseIterable {
    case exact
    case fuzzy
    case fuzzyPlus  // v0.19.1: 分词 + 每词模糊匹配
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
/// v0.21: 预计算 metadata，避免视图渲染时重复 O(n) 字符串操作
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

    // v0.21: 预计算的 metadata，避免视图渲染时重复计算
    let cachedTitle: String
    let cachedMetadata: String

    /// 标准初始化器 - 自动计算 title 和 metadata
    init(
        id: UUID,
        type: ClipboardItemType,
        contentHash: String,
        plainText: String,
        appBundleID: String?,
        createdAt: Date,
        lastUsedAt: Date,
        isPinned: Bool,
        sizeBytes: Int,
        thumbnailPath: String?,
        storageRef: String?
    ) {
        self.id = id
        self.type = type
        self.contentHash = contentHash
        self.plainText = plainText
        self.appBundleID = appBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.sizeBytes = sizeBytes
        self.thumbnailPath = thumbnailPath
        self.storageRef = storageRef

        // 预计算 title 和 metadata
        self.cachedTitle = Self.computeTitle(type: type, plainText: plainText)
        self.cachedMetadata = Self.computeMetadata(type: type, plainText: plainText, sizeBytes: sizeBytes)
    }

    /// v0.16.2: 创建带有更新 isPinned 的新实例
    /// v0.23: 修复 - 使用 let 替代未使用的 var
    func withPinned(_ pinned: Bool) -> ClipboardItemDTO {
        let copy = ClipboardItemDTO(
            id: id,
            type: type,
            contentHash: contentHash,
            plainText: plainText,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            isPinned: pinned,
            sizeBytes: sizeBytes,
            thumbnailPath: thumbnailPath,
            storageRef: storageRef
        )
        return copy
    }

    // 用于 UI 显示 - 使用预计算值
    var title: String { cachedTitle }

    /// v0.21: 预计算的 metadata - 避免视图渲染时 O(n) 操作
    var metadata: String { cachedMetadata }

    // MARK: - Static Computation Methods

    private static func computeTitle(type: ClipboardItemType, plainText: String) -> String {
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
            // v0.15.1: 简化为 "Image"，详细信息在元数据中显示
            return "Image"
        default:
            return plainText.isEmpty ? "(No text)" : String(plainText.prefix(100))
        }
    }

    private static func computeMetadata(type: ClipboardItemType, plainText: String, sizeBytes: Int) -> String {
        switch type {
        case .text, .rtf, .html:
            return computeTextMetadata(plainText)
        case .image:
            return computeImageMetadata(plainText, sizeBytes: sizeBytes)
        case .file:
            return computeFileMetadata(plainText, sizeBytes: sizeBytes)
        default:
            return formatBytes(sizeBytes)
        }
    }

    private static func computeTextMetadata(_ text: String) -> String {
        let charCount = text.count
        let lineCount = text.components(separatedBy: .newlines).count
        // 显示最后15个字符（去除换行符，替换为空格）
        let cleanText = text.replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
        let lastChars = cleanText.count <= 15 ? cleanText : "...\(String(cleanText.suffix(15)))"
        return "\(charCount)字 · \(lineCount)行 · \(lastChars)"
    }

    private static func computeImageMetadata(_ plainText: String, sizeBytes: Int) -> String {
        let size = formatBytes(sizeBytes)
        if let resolution = parseImageResolution(from: plainText) {
            return "\(resolution) · \(size)"
        }
        return size
    }

    private static func computeFileMetadata(_ plainText: String, sizeBytes: Int) -> String {
        let paths = plainText.components(separatedBy: "\n").filter { !$0.isEmpty }
        let fileCount = paths.count
        let size = formatBytes(sizeBytes)
        if fileCount == 1 {
            return size
        }
        return "\(fileCount)个文件 · \(size)"
    }

    private static func parseImageResolution(from text: String) -> String? {
        let pattern = #"\[Image:\s*(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return "\(text[widthRange])×\(text[heightRange])"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        } else {
            return String(format: "%.1f MB", kb / 1024)
        }
    }
}

/// 搜索请求 - 对应 v0.md 中的 SearchRequest
/// v0.22: 添加 typeFilters 支持多类型过滤（如 Rich Text = rtf + html）
struct SearchRequest: Sendable {
    let query: String
    let mode: SearchMode
    let appFilter: String?
    let typeFilter: ClipboardItemType?
    /// v0.22: 多类型过滤，优先于 typeFilter
    let typeFilters: Set<ClipboardItemType>?
    /// v0.29: 渐进搜索 - 是否强制使用全量 fuzzy（禁用首屏预筛）
    let forceFullFuzzy: Bool
    let limit: Int
    let offset: Int

    init(
        query: String,
        mode: SearchMode = SettingsDTO.default.defaultSearchMode,
        appFilter: String? = nil,
        typeFilter: ClipboardItemType? = nil,
        typeFilters: Set<ClipboardItemType>? = nil,
        forceFullFuzzy: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.query = query
        self.mode = mode
        self.appFilter = appFilter
        self.typeFilter = typeFilter
        self.typeFilters = typeFilters
        self.forceFullFuzzy = forceFullFuzzy
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
        defaultSearchMode: .fuzzyPlus,
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
    let thumbnailSizeBytes: Int  // v0.15.2: 缩略图缓存大小
    let totalSizeBytes: Int
    let databasePath: String

    var databaseSizeText: String {
        formatBytes(databaseSizeBytes)
    }

    var externalStorageSizeText: String {
        formatBytes(externalStorageSizeBytes)
    }

    var thumbnailSizeText: String {
        formatBytes(thumbnailSizeBytes)
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
