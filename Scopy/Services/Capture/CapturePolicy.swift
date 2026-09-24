import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ClipboardMonitor {
    // MARK: - File URL Serialization

    /// 序列化文件 URL 数组为 Data
    /// 使用文件路径而非 absoluteString，确保反序列化时能正确还原为文件 URL
    nonisolated static func serializeFileURLs(_ urls: [URL]) -> Data? {
        do {
            // 使用 .path 而非 .absoluteString，避免 file:// 前缀问题
            let paths = urls.map { $0.path }
            return try JSONEncoder().encode(paths)
        } catch {
            ScopyLog.monitor.error("Failed to serialize file URLs: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Central dedup key policy, shared by small-content capture and durable ingest replay.
    nonisolated static func contentHash(
        type: ClipboardItemType,
        plainText: String,
        payloadData: Data?,
        precomputedHash: String?
    ) -> String {
        if let precomputedHash {
            return precomputedHash
        }

        // Text, RTF and HTML intentionally deduplicate by normalized visible text. File
        // captures need a distinct namespace because the same path string has different
        // replay semantics when copied as plain text.
        switch type {
        case .text, .rtf, .html:
            if !plainText.isEmpty {
                return computeHashStatic(Data(plainText.utf8))
            }
            if let payloadData {
                return computeHashStatic(payloadData)
            }
            return computeHashStatic(Data())
        case .file:
            return "file:" + computeHashStatic(Data(plainText.utf8))
        case .image:
            if let payloadData {
                return computeHashStatic(payloadData)
            }
            return computeHashStatic(Data(plainText.utf8))
        case .other:
            if let payloadData {
                return computeHashStatic(payloadData)
            }
            return computeHashStatic(Data(plainText.utf8))
        }
    }

    nonisolated static func isLikelyTemporaryImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"
        ]
        guard imageExtensions.contains(ext) else { return false }

        let path = url.standardizedFileURL.path.lowercased()
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") { return true }
        if path.contains("/var/folders/") { return true }
        if path.contains("/library/caches/") { return true }
        if path.contains("/library/containers/com.tencent.xinwechat/"),
           (path.contains("/temp/") || path.contains("/rwtemp/") || path.contains("/xwechat_files/")) {
            return true
        }
        if path.contains("/xwechat_files/"),
           (path.contains("/temp/") || path.contains("/rwtemp/")) {
            return true
        }
        return false
    }

    nonisolated static func loadImageFileDataAsPNG(_ url: URL) -> Data? {
        guard isLikelyTemporaryImageFileURL(url) else { return nil }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return nil
        }

        if PngquantService.isLikelyPNG(fileData) {
            return fileData
        }

        return convertTIFFToPNG(fileData)
    }

    nonisolated static func htmlLooksLikeOfficeSpreadsheet(_ htmlData: Data) -> Bool {
        // 仅扫描前面一小段，避免大表格导致不必要的开销。
        let sample = String(decoding: htmlData.prefix(16 * 1024), as: UTF8.self).lowercased()

        // 复制图片（浏览器/设计工具）常见为 <img ...>；即便 HTML 包在 table 中，也不应抢走 image。
        if sample.contains("<img") { return false }

        // Excel/Office 常见签名（不要求全部命中；任一命中即可）
        if sample.contains("urn:schemas-microsoft-com:office:excel") { return true }
        if sample.contains("microsoft excel") { return true }
        if sample.contains("mso-") { return true }

        // 兜底：明确的表格结构（Excel 复制单元格基本都会包含）
        if sample.contains("<table") && (sample.contains("<td") || sample.contains("<tr")) {
            return true
        }

        return false
    }

    nonisolated static func rtfLooksLikeTable(_ rtfData: Data) -> Bool {
        let sample = String(decoding: rtfData.prefix(16 * 1024), as: UTF8.self).lowercased()
        // RTF 表格常见控制字：\trowd / \cell
        return sample.contains("\\trowd") || sample.contains("\\cell")
    }

    nonisolated static func stringLooksLikeTabularData(_ string: String) -> Bool {
        // Excel/Sheets 复制单元格的 plain text 往往是 TSV（列用 tab，行用 \n）。
        // 注意：不要仅凭“多行”就判定为表格，否则可能误伤“复制图片 + 多行文本描述”的场景。
        return string.contains("\t")
    }

    /// 静态哈希计算方法（可在任意线程调用）
    public nonisolated static func computeHashStatic(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - TIFF to PNG Conversion

    /// 将 TIFF 数据转换为 PNG 格式（避免存储膨胀）
    /// macOS 剪贴板对截图返回 TIFF（未压缩），可能比原始 PNG 大 35 倍
    nonisolated static func convertTIFFToPNG(_ tiffData: Data) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImageFromSource(destination, imageSource, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
