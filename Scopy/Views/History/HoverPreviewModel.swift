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
    @Published var isMarkdown: Bool = false
}
