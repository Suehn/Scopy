import Foundation

/// Version and build information read from the bundle.
public enum AppVersion {
    /// Marketing version, e.g. "0.81.0".
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
    }

    /// Build number, e.g. "1".
    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Version and build, e.g. "0.81.0 (1)".
    public static var fullVersion: String {
        "\(version) (\(build))"
    }

    /// Approximate build date: the bundle's modification date.
    public static var buildDate: String {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              let attributes = try? FileManager.default.attributesOfItem(atPath: bundleURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return String(localized: "Unknown")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: modificationDate)
    }

    public static var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Scopy"
    }

    /// Bundle ID
    public static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.scopy.app"
    }
}
