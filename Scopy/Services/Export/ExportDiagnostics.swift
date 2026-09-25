import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

extension ExportCoordinator {
    func dumpTableMetricsIfRequested(webView: WKWebView) async {
        guard !didDumpTableMetrics else { return }
        guard let path = ProcessInfo.processInfo.environment["SCOPY_EXPORT_TABLE_METRICS_PATH"], !path.isEmpty else { return }

        let widthPoints = Double(viewportWidthPoints)
        let js = "window.ScopyDocument.export.tableMetrics(\(widthPoints))"

        let content = (try? await evaluateJavaScriptString(webView: webView, javaScriptString: js)) ?? ""
        try? Data(content.utf8).write(to: URL(fileURLWithPath: path), options: [.atomic])
        didDumpTableMetrics = true
    }


    func layoutDebugInfo(webView: WKWebView) async throws -> String {
        let js = "window.ScopyDocument.export.layoutDebugInfo()"
        return try await evaluateJavaScriptString(webView: webView, javaScriptString: js)
    }

    nonisolated static func parseNumberFromLayoutDebugInfo(_ value: String, key: String) -> CGFloat? {
        guard let data = value.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let number = obj[key] as? NSNumber { return max(0, CGFloat(truncating: number)) }
        if let double = obj[key] as? Double { return max(0, CGFloat(double)) }
        if let int = obj[key] as? Int { return max(0, CGFloat(int)) }
        if let string = obj[key] as? String, let value = Double(string) { return max(0, CGFloat(value)) }
        return nil
    }
}
