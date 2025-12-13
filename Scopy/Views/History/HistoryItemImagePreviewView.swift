import SwiftUI
import AppKit

struct HistoryItemImagePreviewView: View {
    let previewImageData: Data?

    var body: some View {
        if let imageData = previewImageData,
           let nsImage = NSImage(data: imageData) {
            let maxWidth: CGFloat = ScopySize.Width.previewMax
            let originalWidth = nsImage.size.width
            let originalHeight = nsImage.size.height

            if originalWidth <= maxWidth {
                Image(nsImage: nsImage)
                    .padding(ScopySpacing.md)
            } else {
                let aspectRatio = originalWidth / originalHeight
                let displayWidth = maxWidth
                let displayHeight = displayWidth / aspectRatio

                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displayWidth, height: displayHeight)
                    .padding(ScopySpacing.md)
            }
        } else {
            ProgressView()
                .padding()
        }
    }
}

