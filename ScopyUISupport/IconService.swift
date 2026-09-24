import AppKit
import Foundation

/// Centralized app icon/name cache.
@MainActor
public final class IconService {
    public static let shared = IconService()

    private let iconCache: NSCache<NSString, NSImage>
    private let nameCache: NSCache<NSString, NSString>
    /// Bundle IDs with no installed application, so rows of uninstalled apps do not ask
    /// LaunchServices again on every render.
    private var missingBundleIDs: Set<String> = []

    private init() {
        let iconCache = NSCache<NSString, NSImage>()
        iconCache.countLimit = 500
        self.iconCache = iconCache

        let nameCache = NSCache<NSString, NSString>()
        nameCache.countLimit = 500
        self.nameCache = nameCache
    }

    public func cachedIcon(bundleID: String) -> NSImage? {
        iconCache.object(forKey: bundleID as NSString)
    }

    public func icon(bundleID: String) -> NSImage? {
        if let cached = cachedIcon(bundleID: bundleID) {
            return cached
        }
        guard !missingBundleIDs.contains(bundleID) else { return nil }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingBundleIDs.insert(bundleID)
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    public func preloadIcon(bundleID: String) {
        _ = icon(bundleID: bundleID)
    }

    public func appName(bundleID: String) -> String {
        if let cached = nameCache.object(forKey: bundleID as NSString) {
            return cached as String
        }

        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = bundleID
        }

        nameCache.setObject(name as NSString, forKey: bundleID as NSString)
        return name
    }

    public func clearAll() {
        iconCache.removeAllObjects()
        nameCache.removeAllObjects()
        missingBundleIDs.removeAll()
    }
}
