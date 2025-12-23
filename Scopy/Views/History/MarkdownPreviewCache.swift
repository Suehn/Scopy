import Foundation
import CoreGraphics

final class MarkdownPreviewCache {
    static let shared = MarkdownPreviewCache()

    private final class MetricsBox: NSObject {
        let metrics: MarkdownContentMetrics

        init(_ metrics: MarkdownContentMetrics) {
            self.metrics = metrics
        }
    }

    private let htmlCache = NSCache<NSString, NSString>()
    private let metricsCache = NSCache<NSString, MetricsBox>()

    private init() {
        htmlCache.countLimit = 200
        htmlCache.totalCostLimit = 8 * 1024 * 1024

        // Metrics are tiny; keep a slightly larger count cap to improve re-hover stability.
        metricsCache.countLimit = 400
    }

    func html(forKey key: String) -> String? {
        htmlCache.object(forKey: key as NSString) as String?
    }

    func setHTML(_ html: String, forKey key: String) {
        let cost = html.utf16.count * 2
        htmlCache.setObject(html as NSString, forKey: key as NSString, cost: cost)
    }

    func metrics(forKey key: String) -> MarkdownContentMetrics? {
        metricsCache.object(forKey: key as NSString)?.metrics
    }

    func setMetrics(_ metrics: MarkdownContentMetrics, forKey key: String) {
        metricsCache.setObject(MetricsBox(metrics), forKey: key as NSString)
    }
}
