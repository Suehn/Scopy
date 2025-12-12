import Foundation

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

