import AppKit
import QuickLookUI
import SwiftUI

private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        self.previewItemURL = url
        super.init()
    }
}

struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL
    var style: QLPreviewViewStyle = .normal

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> QLPreviewView {
        guard let view = QLPreviewView(frame: .zero, style: style) else {
            return QLPreviewView(frame: .zero, style: .compact)!
        }
        view.shouldCloseWithWindow = true
        view.autostarts = true
        context.coordinator.setPreview(url: url, in: view)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.setPreview(url: url, in: nsView)
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        nsView.close()
    }

    final class Coordinator {
        private var currentURL: URL?
        private var previewItem: QuickLookPreviewItem?

        func setPreview(url: URL, in view: QLPreviewView) {
            guard currentURL?.path != url.path else { return }
            currentURL = url
            let item = QuickLookPreviewItem(url: url)
            previewItem = item
            view.previewItem = item
        }
    }
}
