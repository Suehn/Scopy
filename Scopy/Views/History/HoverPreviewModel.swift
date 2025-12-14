import Combine
import Foundation

@MainActor
final class HoverPreviewModel: ObservableObject {
    @Published var imageData: Data?
    @Published var text: String?
}

