import Foundation

/// 本地化相关的轻量工具
enum Localization {
    /// 使用系统的 ByteCountFormatter，自动适配语言/单位
    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

