import Combine
import CoreGraphics
import Foundation

@MainActor
final class HoverPreviewModel: ObservableObject {
    @Published var previewCGImage: CGImage?
    @Published var text: String?
    @Published var markdownHTML: String?
    @Published var markdownContentSize: CGSize?
    @Published var markdownHasHorizontalOverflow: Bool = false
    @Published var markdownRenderSucceeded: Bool = false
    @Published var markdownRenderErrorReason: String?
    @Published var isMarkdown: Bool = false

    // Export state
    @Published var isExporting: Bool = false
    @Published var exportSuccess: Bool = false
    @Published var exportSuccessMessage: String?
    @Published var exportFailed: Bool = false
    @Published var exportErrorMessage: String?

    func reset() {
        previewCGImage = nil
        text = nil
        markdownHTML = nil
        markdownContentSize = nil
        markdownHasHorizontalOverflow = false
        markdownRenderSucceeded = false
        markdownRenderErrorReason = nil
        isMarkdown = false
        isExporting = false
        exportSuccess = false
        exportSuccessMessage = nil
        exportFailed = false
        exportErrorMessage = nil
    }
}
