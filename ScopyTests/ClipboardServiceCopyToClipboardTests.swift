import AppKit
import XCTest
import ScopyKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ClipboardServiceCopyToClipboardTests: XCTestCase {
    private var service: (any ClipboardServiceProtocol)!
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!
    private var settingsSuiteName: String?
    private var tempDirectory: URL?
    private var insertedItemID: UUID?
    private var insertedHTMLData: Data?

    override func setUp() async throws {
        let suiteName = "scopy-copy-settings-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settingsSuiteName = suiteName
        settingsStore = SettingsStore(suiteName: suiteName)

        pasteboard = NSPasteboard.withUniqueName()

        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        tempDirectory = baseURL

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        // Insert an HTML item whose stored plainText is empty (simulates older broken data).
        let html = "<html><body>你好 Hello</body></html>"
        guard let htmlData = html.data(using: .utf16) else {
            throw XCTSkip("Unable to encode HTML data as UTF-16")
        }
        insertedHTMLData = htmlData

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        let storedItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .html,
                plainText: "",
                payload: .data(htmlData),
                appBundleID: "com.test.app",
                contentHash: UUID().uuidString,
                sizeBytes: htmlData.count
            )
        )
        insertedItemID = storedItem.id
        await storage.close()

        service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 5.0
        )
        try await service.start()
    }

    override func tearDown() async throws {
        if let service {
            await service.stopAndWait()
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        insertedItemID = nil
        insertedHTMLData = nil
        service = nil
        pasteboard = nil
        settingsStore = nil
        if let suiteName = settingsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        settingsSuiteName = nil
    }

    func testCopyToClipboardHTMLWhenStoredPlainTextIsEmptyWritesPlainString() async throws {
        guard let insertedItemID else {
            XCTFail("Missing inserted item ID")
            return
        }
        guard let insertedHTMLData else {
            XCTFail("Missing inserted html data")
            return
        }

        let items = try await service.fetchRecent(limit: 20, offset: 0)
        guard let item = items.first(where: { $0.id == insertedItemID }) else {
            XCTFail("Inserted item not found")
            return
        }
        XCTAssertEqual(item.type, .html)
        XCTAssertTrue(item.plainText.isEmpty)

        try await service.copyToClipboard(itemID: insertedItemID)

        XCTAssertEqual(pasteboard.data(forType: .html), insertedHTMLData)
        let plainString = pasteboard.string(forType: .string) ?? ""
        XCTAssertFalse(plainString.isEmpty)
        XCTAssertTrue(plainString.contains("你好"))
        XCTAssertTrue(plainString.contains("Hello"))
    }

    func testCopyToClipboardImagePNGDataWritesPNGType() async throws {
        let pngData = try Self.makeTestPNGData()
        try await service.copyToClipboard(imagePNGData: pngData)
        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
    }

    private static func makeTestPNGData() throws -> Data {
        let width = 2
        let height = 2
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
            buffer[i + 0] = 0x00 // R
            buffer[i + 1] = 0x00 // G
            buffer[i + 2] = 0x00 // B
            buffer[i + 3] = 0xFF // A
        }

        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else {
            throw XCTSkip("Unable to create CGDataProvider")
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw XCTSkip("Unable to create CGImage")
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("Unable to create PNG destination")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("Unable to finalize PNG destination")
        }
        return out as Data
    }
}
