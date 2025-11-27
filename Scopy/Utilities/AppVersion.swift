import Foundation

/// 应用版本信息工具
/// v0.6: 动态读取版本号和构建信息
enum AppVersion {
    /// 应用版本号 (e.g., "0.6.0")
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// 构建号 (e.g., "1")
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 完整版本字符串 (e.g., "0.6.0 (1)")
    static var fullVersion: String {
        "\(version) (\(build))"
    }

    /// 构建日期
    /// 通过读取应用 bundle 的修改时间获取近似构建日期
    static var buildDate: String {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              let attributes = try? FileManager.default.attributesOfItem(atPath: bundleURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return "Unknown"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: modificationDate)
    }

    /// 带日期的完整版本信息 (e.g., "0.6.0 (1) - 2025-11-27")
    static var versionWithDate: String {
        "\(fullVersion) - \(buildDate)"
    }

    /// 应用名称
    static var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Scopy"
    }

    /// Bundle ID
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.scopy.app"
    }
}
