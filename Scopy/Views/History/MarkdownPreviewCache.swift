import Foundation

final class MarkdownPreviewCache {
    static let shared = MarkdownPreviewCache()

    private let cache = NSCache<NSString, NSString>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func html(forKey key: String) -> String? {
        cache.object(forKey: key as NSString) as String?
    }

    func setHTML(_ html: String, forKey key: String) {
        let cost = html.utf16.count * 2
        cache.setObject(html as NSString, forKey: key as NSString, cost: cost)
    }
}
