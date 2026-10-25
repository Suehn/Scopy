import AppKit
import Foundation

/// Resolves each application's name and icon from one cached LaunchServices result.
@MainActor
public final class IconService {
    public static let shared = IconService()

    private final class Application {
        let url: URL?
        let name: String
        var icon: NSImage?

        init(bundleID: String, url: URL?) {
            self.url = url
            self.name = url?.deletingPathExtension().lastPathComponent ?? bundleID
        }
    }

    private let applications = NSCache<NSString, Application>()

    private init() {
        applications.countLimit = 500
    }

    public func cachedIcon(bundleID: String) -> NSImage? {
        applications.object(forKey: bundleID as NSString)?.icon
    }

    public func icon(bundleID: String) -> NSImage? {
        let application = application(bundleID: bundleID)
        if let icon = application.icon { return icon }
        guard let url = application.url else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        application.icon = icon
        return icon
    }

    public func preloadIcon(bundleID: String) {
        _ = icon(bundleID: bundleID)
    }

    public func appName(bundleID: String) -> String {
        application(bundleID: bundleID).name
    }

    public func clearAll() {
        applications.removeAllObjects()
    }

    private func application(bundleID: String) -> Application {
        let key = bundleID as NSString
        if let cached = applications.object(forKey: key) { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let application = Application(bundleID: bundleID, url: url)
        applications.setObject(application, forKey: key)
#if DEBUG
        lookupCountForTesting += 1
#endif
        return application
    }

#if DEBUG
    private(set) var lookupCountForTesting = 0

    static func makeForTesting() -> IconService {
        IconService()
    }
#endif
}
