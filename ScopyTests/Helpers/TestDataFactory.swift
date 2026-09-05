import Foundation
import ScopyKit

enum TestDataFactory {

    static func makeTextContent(
        _ text: String,
        appBundleID: String = "com.test.app"
    ) -> ClipboardMonitor.ClipboardContent {
        ClipboardMonitor.ClipboardContent(
            type: .text,
            plainText: text,
            payload: .none,
            appBundleID: appBundleID,
            contentHash: computeHash(text),
            sizeBytes: text.utf8.count
        )
    }

    static func makeImageContent(
        width: Int = 100,
        height: Int = 100,
        appBundleID: String = "com.test.app"
    ) -> ClipboardMonitor.ClipboardContent {
        // Generate fake image data
        let dataSize = width * height * 4 // RGBA
        let data = Data(repeating: 0xFF, count: dataSize)
        let hash = "image_\(width)x\(height)_\(UUID().uuidString.prefix(8))"

        return ClipboardMonitor.ClipboardContent(
            type: .image,
            plainText: "",
            payload: .data(data),
            appBundleID: appBundleID,
            contentHash: hash,
            sizeBytes: dataSize
        )
    }

    static func makeItem(
        id: UUID = UUID(),
        plainText: String,
        appBundleID: String = "com.test.app",
        isPinned: Bool = false,
        createdAt: Date = Date()
    ) -> ClipboardItemDTO {
        ClipboardItemDTO(
            id: id,
            type: .text,
            contentHash: computeHash(plainText),
            plainText: plainText,
            appBundleID: appBundleID,
            createdAt: createdAt,
            lastUsedAt: createdAt,
            isPinned: isPinned,
            sizeBytes: plainText.utf8.count,
            thumbnailPath: nil,
            storageRef: nil
        )
    }

    static func makeItems(
        count: Int,
        prefix: String = "Test item",
        appBundleID: String = "com.test.app"
    ) -> [ClipboardItemDTO] {
        (0..<count).map { i in
            makeItem(
                plainText: "\(prefix) \(i)",
                appBundleID: appBundleID,
                createdAt: Date().addingTimeInterval(Double(-i))
            )
        }
    }

    private static func computeHash(_ text: String) -> String {
        String(text.hashValue)
    }
}
